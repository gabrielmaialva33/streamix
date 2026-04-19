defmodule Streamix.Iptv.StreamMultiplexer do
  @moduledoc """
  Manages a single upstream Mint.HTTP connection for a specific live stream,
  broadcasting chunks to all subscribers via Phoenix.PubSub.

  Maintains a ring buffer of recent chunks so new subscribers get instant playback.
  Auto-shuts down after an idle timeout with no subscribers.
  """
  use GenServer, restart: :transient

  require Logger

  alias Streamix.Iptv.StreamMultiplexerSupervisor

  @connect_timeout 10_000
  @idle_timeout 30_000
  @default_buffer_size 30
  @max_buffer_bytes 5 * 1_024 * 1_024

  # -- Public API --

  @doc """
  Subscribe the calling process to a stream.
  Starts the multiplexer if not already running.
  Returns `{:ok, backlog}` where backlog is a list of recent chunks for instant playback.
  """
  def subscribe(stream_key, url) do
    case start_or_lookup(stream_key, url) do
      {:ok, pid} ->
        GenServer.call(pid, {:subscribe, self()})

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Unsubscribe the calling process from a stream.
  If this was the last subscriber, the multiplexer will shut down after idle timeout.
  """
  def unsubscribe(stream_key) do
    case Registry.lookup(Streamix.StreamRegistry, stream_key) do
      [{pid, _}] ->
        GenServer.cast(pid, {:unsubscribe, self()})

      [] ->
        :ok
    end
  end

  @doc false
  def start_link(args) do
    stream_key = Keyword.fetch!(args, :stream_key)

    GenServer.start_link(__MODULE__, args,
      name: {:via, Registry, {Streamix.StreamRegistry, stream_key}}
    )
  end

  # -- Internals --

  defp start_or_lookup(stream_key, url) do
    # Skip Registry.lookup — go straight to start_child which is atomic
    # via the :via Registry name. This avoids the lookup-then-start race.
    case StreamMultiplexerSupervisor.start_child(stream_key: stream_key, url: url) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        # Another process may have started and already stopped.
        # Final lookup to be safe before giving up.
        case Registry.lookup(Streamix.StreamRegistry, stream_key) do
          [{pid, _}] -> {:ok, pid}
          [] -> {:error, reason}
        end
    end
  end

  # -- GenServer callbacks --

  @impl true
  def init(args) do
    stream_key = Keyword.fetch!(args, :stream_key)
    url = Keyword.fetch!(args, :url)
    buffer_size = Keyword.get(args, :buffer_size, @default_buffer_size)

    Logger.info("[StreamMux] Starting multiplexer for stream_key=#{stream_key}")

    state = %{
      stream_key: stream_key,
      url: url,
      mint_conn: nil,
      request_ref: nil,
      subscribers: MapSet.new(),
      buffer: :queue.new(),
      buffer_size: buffer_size,
      buffer_count: 0,
      buffer_bytes: 0,
      status: :connecting,
      idle_timer: nil
    }

    # Connect async to avoid blocking the supervisor
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect_upstream(state.url) do
      {:ok, mint_conn, request_ref} ->
        {:noreply, %{state | mint_conn: mint_conn, request_ref: request_ref, status: :streaming}}

      {:error, reason} ->
        Logger.error(
          "[StreamMux] Failed to connect upstream for #{state.stream_key}: #{inspect(reason)}"
        )

        broadcast(state.stream_key, {:stream_error, reason})
        {:stop, {:shutdown, :connect_failed}, state}
    end
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)

    new_subscribers = MapSet.put(state.subscribers, pid)

    # Cancel idle timer since we have a subscriber
    state = cancel_idle_timer(state)

    # Send backlog for instant playback
    backlog = :queue.to_list(state.buffer)

    {:reply, {:ok, backlog}, %{state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    new_subscribers = MapSet.delete(state.subscribers, pid)
    state = %{state | subscribers: new_subscribers}
    state = maybe_start_idle_timer(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:ssl, _socket, _data} = message, state) do
    handle_mint_message(message, state)
  end

  def handle_info({:tcp, _socket, _data} = message, state) do
    handle_mint_message(message, state)
  end

  def handle_info({:ssl_closed, _socket} = message, state) do
    handle_mint_message(message, state)
  end

  def handle_info({:tcp_closed, _socket} = message, state) do
    handle_mint_message(message, state)
  end

  def handle_info({:ssl_error, _socket, _reason} = message, state) do
    handle_mint_message(message, state)
  end

  def handle_info({:tcp_error, _socket, _reason} = message, state) do
    handle_mint_message(message, state)
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_subscribers = MapSet.delete(state.subscribers, pid)
    state = %{state | subscribers: new_subscribers}
    state = maybe_start_idle_timer(state)
    {:noreply, state}
  end

  def handle_info(:idle_timeout, state) do
    if MapSet.size(state.subscribers) == 0 do
      Logger.info("[StreamMux] Idle timeout, shutting down #{state.stream_key}")
      close_upstream(state)
      {:stop, :normal, %{state | idle_timer: nil}}
    else
      # Subscribers joined between timer fire and check — keep running.
      # Don't touch idle_timer; a new one will be set when subscribers leave.
      {:noreply, state}
    end
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    close_upstream(state)
    :ok
  end

  # -- Mint message handling --

  defp handle_mint_message(message, %{mint_conn: nil} = state) do
    Logger.debug("[StreamMux] Received message with no connection: #{inspect(message)}")
    {:noreply, state}
  end

  defp handle_mint_message(message, state) do
    case Mint.HTTP.stream(state.mint_conn, message) do
      :unknown ->
        {:noreply, state}

      {:ok, mint_conn, responses} ->
        state = %{state | mint_conn: mint_conn}

        case process_responses(responses, state) do
          {:ok, state} ->
            {:noreply, state}

          {:stop, state} ->
            {:stop, {:shutdown, :redirect_failed}, state}
        end

      {:error, mint_conn, reason, _responses} ->
        Logger.error("[StreamMux] Stream error for #{state.stream_key}: #{inspect(reason)}")
        state = %{state | mint_conn: mint_conn}
        broadcast(state.stream_key, {:stream_error, reason})
        # Attempt reconnect
        {:noreply, state, {:continue, :connect}}
    end
  end

  defp process_responses([], state), do: {:ok, state}

  defp process_responses([response | rest], state) do
    case process_response(response, state) do
      {:ok, new_state} -> process_responses(rest, new_state)
      {:stop, _state} = stop -> stop
    end
  end

  defp process_response({:status, _ref, status}, state) do
    Logger.debug("[StreamMux] Upstream status: #{status}")

    if status in [301, 302, 303, 307, 308] do
      {:ok, %{state | status: {:redirect, status}}}
    else
      {:ok, state}
    end
  end

  defp process_response({:headers, _ref, headers}, %{status: {:redirect, _}} = state) do
    handle_redirect_headers(headers, state)
  end

  defp process_response({:headers, _ref, _headers}, state) do
    Logger.debug("[StreamMux] Upstream headers received")
    {:ok, state}
  end

  defp process_response({:data, _ref, chunk}, state), do: {:ok, push_chunk(chunk, state)}

  defp process_response({:done, _ref}, state) do
    Logger.info("[StreamMux] Upstream done for #{state.stream_key}")
    broadcast(state.stream_key, :stream_done)
    {:ok, state}
  end

  defp process_response({:error, _ref, reason}, state) do
    Logger.error("[StreamMux] Upstream error for #{state.stream_key}: #{inspect(reason)}")
    broadcast(state.stream_key, {:stream_error, reason})
    {:ok, state}
  end

  defp process_response(_response, state), do: {:ok, state}

  defp handle_redirect_headers(headers, state) do
    location =
      Enum.find_value(headers, fn
        {"location", value} -> value
        _ -> nil
      end)

    case location do
      nil ->
        Logger.error("[StreamMux] Redirect without Location header")
        {:ok, state}

      location ->
        follow_redirect(resolve_url(state.url, location), state)
    end
  end

  defp follow_redirect(redirect_url, state) do
    case StreamixWeb.UrlValidator.validate_url(redirect_url) do
      :ok ->
        reconnect_redirect(redirect_url, state)

      {:error, reason} ->
        Logger.error("[StreamMux] SSRF blocked redirect to #{redirect_url}")
        close_upstream(state)
        stop_with_stream_error(reason, state)
    end
  end

  defp reconnect_redirect(redirect_url, state) do
    Logger.info("[StreamMux] Following redirect to #{redirect_url}")
    close_upstream(state)

    case connect_upstream(redirect_url) do
      {:ok, mint_conn, request_ref} ->
        {:ok,
         %{
           state
           | mint_conn: mint_conn,
             request_ref: request_ref,
             url: redirect_url,
             status: :streaming
         }}

      {:error, reason} ->
        Logger.error("[StreamMux] Redirect connect failed: #{inspect(reason)}")
        stop_with_stream_error(reason, state)
    end
  end

  defp stop_with_stream_error(reason, state) do
    broadcast(state.stream_key, {:stream_error, reason})
    {:stop, %{state | mint_conn: nil, request_ref: nil, status: :error}}
  end

  defp push_chunk(chunk, state) do
    # Broadcast to all subscribers
    broadcast(state.stream_key, {:stream_chunk, chunk})

    chunk_size = byte_size(chunk)

    # Add to ring buffer
    buffer = :queue.in(chunk, state.buffer)
    count = state.buffer_count + 1
    bytes = state.buffer_bytes + chunk_size

    # Trim by chunk count limit
    {buffer, count, bytes} = trim_buffer_by_count(buffer, count, bytes, state.buffer_size)

    # Trim by byte size limit
    {buffer, count, bytes} = trim_buffer_by_bytes(buffer, count, bytes, @max_buffer_bytes)

    %{state | buffer: buffer, buffer_count: count, buffer_bytes: bytes}
  end

  defp trim_buffer_by_count(buffer, count, bytes, max_count) when count > max_count do
    {{:value, old_chunk}, buffer} = :queue.out(buffer)
    trim_buffer_by_count(buffer, count - 1, bytes - byte_size(old_chunk), max_count)
  end

  defp trim_buffer_by_count(buffer, count, bytes, _max_count), do: {buffer, count, bytes}

  defp trim_buffer_by_bytes(buffer, count, bytes, max_bytes)
       when count > 1 and bytes > max_bytes do
    {{:value, old_chunk}, buffer} = :queue.out(buffer)
    trim_buffer_by_bytes(buffer, count - 1, bytes - byte_size(old_chunk), max_bytes)
  end

  defp trim_buffer_by_bytes(buffer, count, bytes, _max_bytes), do: {buffer, count, bytes}

  # -- Upstream connection --

  defp connect_upstream(url) do
    uri = URI.parse(url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    port = uri.port || default_port(scheme)
    path = build_request_path(uri)

    transport_opts =
      case scheme do
        :https -> [cacerts: :public_key.cacerts_get(), timeout: @connect_timeout]
        :http -> [timeout: @connect_timeout]
      end

    headers = [
      {"host", uri.host},
      # See StreamProxy.stream_from_url/2 for why we masquerade.
      {"user-agent", "xciptv-v6.0.0"},
      {"accept", "*/*"},
      {"connection", "keep-alive"}
    ]

    with {:ok, mint_conn} <-
           Mint.HTTP.connect(scheme, uri.host, port, transport_opts: transport_opts),
         {:ok, mint_conn, request_ref} <- Mint.HTTP.request(mint_conn, "GET", path, headers, nil) do
      {:ok, mint_conn, request_ref}
    else
      {:error, mint_conn, reason} ->
        close_mint_conn(mint_conn)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp close_upstream(%{mint_conn: nil}), do: :ok

  defp close_upstream(%{mint_conn: mint_conn}) do
    close_mint_conn(mint_conn)
    :ok
  end

  # -- Helpers --

  defp broadcast(stream_key, message) do
    Phoenix.PubSub.broadcast(Streamix.PubSub, "stream:#{stream_key}", message)
  end

  defp cancel_idle_timer(%{idle_timer: nil} = state), do: state

  defp cancel_idle_timer(%{idle_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | idle_timer: nil}
  end

  defp maybe_start_idle_timer(state) do
    if MapSet.size(state.subscribers) == 0 do
      state = cancel_idle_timer(state)
      ref = Process.send_after(self(), :idle_timeout, @idle_timeout)
      %{state | idle_timer: ref}
    else
      state
    end
  end

  defp close_mint_conn(nil), do: :ok

  defp close_mint_conn(mint_conn) do
    Mint.HTTP.close(mint_conn)
    :ok
  rescue
    _ -> :ok
  end

  defp default_port(:https), do: 443
  defp default_port(:http), do: 80

  defp build_request_path(uri) do
    path = uri.path || "/"
    if uri.query, do: "#{path}?#{uri.query}", else: path
  end

  defp resolve_url(base_url, location) do
    if String.starts_with?(location, "http://") or String.starts_with?(location, "https://") do
      location
    else
      base_uri = URI.parse(base_url)
      URI.merge(base_uri, location) |> URI.to_string()
    end
  end
end
