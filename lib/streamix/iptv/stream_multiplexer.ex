defmodule Streamix.Iptv.StreamMultiplexer do
  @moduledoc """
  Manages a single upstream Mint.HTTP connection for a specific live stream,
  broadcasting chunks to all subscribers via Phoenix.PubSub.

  Maintains a ring buffer of recent chunks so new subscribers get instant playback.
  Auto-shuts down after an idle timeout with no subscribers.
  """
  use GenServer, restart: :transient

  require Logger

  @connect_timeout 10_000
  @max_redirects 5
  @idle_timeout 30_000
  @default_buffer_size 30

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
    case Registry.lookup(Streamix.StreamRegistry, stream_key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case Streamix.Iptv.StreamMultiplexerSupervisor.start_child(
               stream_key: stream_key,
               url: url
             ) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, reason} ->
            {:error, reason}
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
      status: :connecting,
      idle_timer: nil
    }

    # Connect async to avoid blocking the supervisor
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect_upstream(state.url, 0) do
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
      {:stop, :normal, state}
    else
      {:noreply, %{state | idle_timer: nil}}
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
        state = process_responses(responses, state)
        {:noreply, state}

      {:error, mint_conn, reason, _responses} ->
        Logger.error("[StreamMux] Stream error for #{state.stream_key}: #{inspect(reason)}")
        state = %{state | mint_conn: mint_conn}
        broadcast(state.stream_key, {:stream_error, reason})
        # Attempt reconnect
        {:noreply, state, {:continue, :connect}}
    end
  end

  defp process_responses([], state), do: state

  defp process_responses([response | rest], state) do
    state =
      case response do
        {:status, _ref, status} ->
          Logger.debug("[StreamMux] Upstream status: #{status}")

          if status in [301, 302, 303, 307, 308] do
            %{state | status: {:redirect, status}}
          else
            state
          end

        {:headers, _ref, headers} ->
          case state.status do
            {:redirect, _} ->
              handle_redirect_headers(headers, state)

            _ ->
              Logger.debug("[StreamMux] Upstream headers received")
              state
          end

        {:data, _ref, chunk} ->
          push_chunk(chunk, state)

        {:done, _ref} ->
          Logger.info("[StreamMux] Upstream done for #{state.stream_key}")
          broadcast(state.stream_key, :stream_done)
          state

        {:error, _ref, reason} ->
          Logger.error("[StreamMux] Upstream error for #{state.stream_key}: #{inspect(reason)}")

          broadcast(state.stream_key, {:stream_error, reason})
          state

        _ ->
          state
      end

    process_responses(rest, state)
  end

  defp handle_redirect_headers(headers, state) do
    location =
      Enum.find_value(headers, fn
        {"location", value} -> value
        _ -> nil
      end)

    if location do
      redirect_url = resolve_url(state.url, location)

      Logger.info("[StreamMux] Following redirect to #{redirect_url}")

      close_upstream(state)

      case connect_upstream(redirect_url, 0) do
        {:ok, mint_conn, request_ref} ->
          %{
            state
            | mint_conn: mint_conn,
              request_ref: request_ref,
              url: redirect_url,
              status: :streaming
          }

        {:error, reason} ->
          Logger.error("[StreamMux] Redirect connect failed: #{inspect(reason)}")
          broadcast(state.stream_key, {:stream_error, reason})
          %{state | mint_conn: nil, request_ref: nil, status: :error}
      end
    else
      Logger.error("[StreamMux] Redirect without Location header")
      state
    end
  end

  defp push_chunk(chunk, state) do
    # Broadcast to all subscribers
    broadcast(state.stream_key, {:stream_chunk, chunk})

    # Add to ring buffer
    {buffer, count} =
      if state.buffer_count >= state.buffer_size do
        {_, buffer} = :queue.out(state.buffer)
        {:queue.in(chunk, buffer), state.buffer_size}
      else
        {:queue.in(chunk, state.buffer), state.buffer_count + 1}
      end

    %{state | buffer: buffer, buffer_count: count}
  end

  # -- Upstream connection --

  defp connect_upstream(_url, redirect_count) when redirect_count > @max_redirects do
    {:error, :too_many_redirects}
  end

  defp connect_upstream(url, _redirect_count) do
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
      {"user-agent", "Streamix/1.0"},
      {"accept", "*/*"},
      {"connection", "keep-alive"}
    ]

    with {:ok, mint_conn} <-
           Mint.HTTP.connect(scheme, uri.host, port, transport_opts: transport_opts),
         {:ok, mint_conn, request_ref} <- Mint.HTTP.request(mint_conn, "GET", path, headers, nil) do
      {:ok, mint_conn, request_ref}
    else
      {:error, mint_conn, reason} when is_struct(mint_conn) ->
        Mint.HTTP.close(mint_conn)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp close_upstream(%{mint_conn: nil}), do: :ok

  defp close_upstream(%{mint_conn: mint_conn}) do
    Mint.HTTP.close(mint_conn)
    :ok
  rescue
    _ -> :ok
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
