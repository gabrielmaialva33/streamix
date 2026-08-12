defmodule Streamix.Iptv.StreamMultiplexer do
  @moduledoc """
  Fans one live upstream connection out to multiple downstream processes.

  Subscribers use explicit demand. Every subscriber has a bounded private
  queue that retains the newest live chunks, so a temporarily slow client
  catches up instead of growing memory indefinitely or being disconnected.
  The upstream connection owns exactly one `ProviderRuntime` lease regardless
  of subscriber count.
  """

  use GenServer, restart: :transient

  require Logger

  alias Streamix.Iptv.Streaming.ProviderRuntime
  alias Streamix.Iptv.Streaming.StreamMultiplexer.{Health, Subscribers, Upstream}
  alias Streamix.Iptv.StreamMultiplexerSupervisor
  alias Streamix.SafeLog
  alias Streamix.Security.UrlValidator

  @connect_timeout 10_000
  @default_idle_timeout 2_000
  @default_buffer_size 30
  @default_subscriber_buffer_bytes 5 * 1_024 * 1_024
  @max_redirects 5
  @redirect_statuses [301, 302, 303, 307, 308]

  @type subscription :: %{
          pid: pid(),
          status: :connecting | :ready,
          response_status: integer() | nil,
          headers: [{String.t(), String.t()}],
          backlog: [binary()]
        }

  @doc "Subscribes the calling process, atomically starting the stream if needed."
  @spec subscribe(term(), String.t() | [String.t()], keyword()) ::
          {:ok, subscription()} | {:error, term()}
  def subscribe(stream_key, urls, opts \\ []) do
    args =
      opts
      |> Keyword.put(:stream_key, stream_key)
      |> Keyword.put(:urls, Upstream.normalize_urls(urls))

    with {:ok, pid} <- start_or_lookup(args) do
      GenServer.call(pid, {:subscribe, self()}, @connect_timeout + 1_000)
    end
  end

  @doc "Requests one queued chunk for the calling subscriber."
  @spec demand(pid()) :: :ok
  def demand(pid) when is_pid(pid) do
    GenServer.cast(pid, {:demand, self()})
  end

  @doc "Unsubscribes the calling process."
  @spec unsubscribe(pid() | term()) :: :ok
  def unsubscribe(pid) when is_pid(pid) do
    GenServer.cast(pid, {:unsubscribe, self()})
  end

  def unsubscribe(stream_key) do
    case Registry.lookup(Streamix.StreamRegistry, stream_key) do
      [{pid, _}] -> unsubscribe(pid)
      [] -> :ok
    end
  end

  @doc false
  def start_link(args) do
    stream_key = Keyword.fetch!(args, :stream_key)

    GenServer.start_link(__MODULE__, args,
      name: {:via, Registry, {Streamix.StreamRegistry, stream_key}}
    )
  end

  @impl true
  def init(args) do
    stream_key = Keyword.fetch!(args, :stream_key)

    state = %{
      stream_key: stream_key,
      urls: Keyword.fetch!(args, :urls),
      url_index: 0,
      current_url: nil,
      provider_id: Keyword.get(args, :provider_id),
      content_id: Keyword.get(args, :content_id),
      url_validator: Keyword.get(args, :url_validator, &UrlValidator.validate_url/1),
      lease: :untracked,
      mint_conn: nil,
      request_ref: nil,
      response_status: nil,
      response_headers: [],
      redirect_count: 0,
      subscribers: %{},
      buffer: :queue.new(),
      buffer_size: Keyword.get(args, :buffer_size, @default_buffer_size),
      buffer_count: 0,
      buffer_bytes: 0,
      subscriber_buffer_bytes:
        Keyword.get(args, :subscriber_buffer_bytes, @default_subscriber_buffer_bytes),
      status: :idle,
      idle_timer: nil,
      idle_timeout:
        Keyword.get(
          args,
          :idle_timeout,
          Application.get_env(:streamix, :live_mux_idle_timeout_ms, @default_idle_timeout)
        ),
      started_at: nil,
      health_recorded?: false
    }

    Logger.info("[StreamMux] ready stream_key=#{inspect(stream_key)}")
    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, _pid}, _from, %{status: status} = state)
      when status in [:done, :error] do
    {:reply, {:error, :stream_ended}, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    {state, _subscriber} = Subscribers.put(state, pid)
    state = Subscribers.cancel_idle_timer(state)

    case ensure_upstream_started(state) do
      {:ok, state} ->
        {:reply, {:ok, subscription(state)}, state}

      {:error, reason, state} ->
        state = Subscribers.remove(state, pid)
        {:reply, {:error, reason}, Subscribers.maybe_start_idle_timer(state)}
    end
  end

  @impl true
  def handle_cast({:demand, pid}, state) do
    {:noreply, Subscribers.demand(state, pid)}
  end

  def handle_cast({:unsubscribe, pid}, state) do
    state = state |> Subscribers.remove(pid) |> Subscribers.maybe_start_idle_timer()
    {:noreply, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect_current_url(state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason, state} ->
        handle_connection_failure(reason, state)
    end
  end

  def handle_info({protocol, _socket, _data} = message, state)
      when protocol in [:ssl, :tcp] do
    handle_mint_message(message, state)
  end

  def handle_info({protocol, _socket} = message, state)
      when protocol in [:ssl_closed, :tcp_closed] do
    handle_mint_message(message, state)
  end

  def handle_info({protocol, _socket, _reason} = message, state)
      when protocol in [:ssl_error, :tcp_error] do
    handle_mint_message(message, state)
  end

  def handle_info({:DOWN, monitor_ref, :process, pid, _reason}, state) do
    case Map.get(state.subscribers, pid) do
      %{monitor_ref: ^monitor_ref} ->
        state =
          state
          |> Subscribers.remove(pid, false)
          |> Subscribers.maybe_start_idle_timer()

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:idle_timeout, state) do
    if map_size(state.subscribers) == 0 do
      Logger.info("[StreamMux] idle shutdown stream_key=#{inspect(state.stream_key)}")
      {:stop, :normal, %{state | idle_timer: nil}}
    else
      {:noreply, %{state | idle_timer: nil}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Upstream.close(state.mint_conn)
    ProviderRuntime.release(state.lease)
    :ok
  end

  defp start_or_lookup(args) do
    case StreamMultiplexerSupervisor.start_child(args) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        stream_key = Keyword.fetch!(args, :stream_key)

        case Registry.lookup(Streamix.StreamRegistry, stream_key) do
          [{pid, _}] -> {:ok, pid}
          [] -> {:error, reason}
        end
    end
  end

  defp ensure_upstream_started(%{status: :idle} = state) do
    case ProviderRuntime.acquire(state.provider_id, :live, self()) do
      {:ok, lease} ->
        send(self(), :connect)

        {:ok,
         %{
           state
           | lease: lease,
             status: :connecting,
             started_at: System.monotonic_time(:millisecond)
         }}

      {:error, :capacity_exhausted} ->
        {:error, :capacity_exhausted, state}
    end
  end

  defp ensure_upstream_started(state), do: {:ok, state}

  defp subscription(%{status: :streaming} = state) do
    %{
      pid: self(),
      status: :ready,
      response_status: state.response_status,
      headers: state.response_headers,
      backlog: :queue.to_list(state.buffer)
    }
  end

  defp subscription(_state) do
    %{pid: self(), status: :connecting, response_status: nil, headers: [], backlog: []}
  end

  defp handle_mint_message(_message, %{mint_conn: nil} = state), do: {:noreply, state}

  defp handle_mint_message(message, state) do
    case Mint.HTTP.stream(state.mint_conn, message) do
      :unknown ->
        {:noreply, state}

      {:ok, mint_conn, responses} ->
        handle_stream_responses(responses, %{state | mint_conn: mint_conn})

      {:error, mint_conn, reason, responses} ->
        handle_stream_error_responses(
          responses,
          reason,
          %{state | mint_conn: mint_conn}
        )
    end
  end

  defp handle_stream_responses(responses, state) do
    case process_responses(responses, state) do
      {:ok, state} -> {:noreply, state}
      {:reconnect, state} -> {:noreply, state}
      {:stop, reason, state} -> stop_after_error(reason, state)
    end
  end

  defp handle_stream_error_responses(responses, transport_reason, state) do
    case process_responses(responses, state) do
      {:ok, state} -> handle_connection_failure(transport_reason, state)
      {:reconnect, state} -> {:noreply, state}
      {:stop, response_reason, state} -> stop_after_error(response_reason, state)
    end
  end

  defp process_responses([], state), do: {:ok, state}

  defp process_responses([response | rest], state) do
    case process_response(response, state) do
      {:ok, state} -> process_responses(rest, state)
      other -> other
    end
  end

  defp process_response({:status, _ref, status}, state) when status in @redirect_statuses do
    {:ok, %{state | response_status: status, status: :redirecting}}
  end

  defp process_response({:status, _ref, status}, state) when status in 200..299 do
    {:ok, %{state | response_status: status}}
  end

  defp process_response({:status, _ref, status}, state) do
    {:stop, {:unexpected_status, status}, %{state | status: :error}}
  end

  defp process_response({:headers, _ref, headers}, %{status: :redirecting} = state) do
    follow_redirect(headers, state)
  end

  defp process_response({:headers, _ref, headers}, state) do
    response_headers = Upstream.filter_response_headers(headers)

    state = %{state | response_headers: response_headers, status: :streaming}
    Subscribers.notify_ready(state)
    {:ok, state}
  end

  defp process_response({:data, _ref, chunk}, state) when is_binary(chunk) do
    state = state |> Health.record_first_success() |> Subscribers.push_chunk(chunk)
    {:ok, state}
  end

  defp process_response({:done, _ref}, state) do
    state = Subscribers.enqueue_terminal(state, :done)
    Upstream.close(state.mint_conn)
    ProviderRuntime.release(state.lease)

    {:ok, %{state | status: :done, mint_conn: nil, request_ref: nil, lease: :untracked}}
  end

  defp process_response({:error, _ref, reason}, state), do: {:stop, reason, state}
  defp process_response(_response, state), do: {:ok, state}

  defp follow_redirect(_headers, %{redirect_count: count} = state)
       when count >= @max_redirects do
    {:stop, :too_many_redirects, state}
  end

  defp follow_redirect(headers, state) do
    with location when is_binary(location) <- Upstream.header_value(headers, "location"),
         redirect_url <- Upstream.resolve_url(state.current_url, location),
         :ok <- state.url_validator.(redirect_url) do
      Upstream.close(state.mint_conn)

      case Upstream.connect(redirect_url, state.url_validator, @connect_timeout) do
        {:ok, mint_conn, request_ref} ->
          {:reconnect,
           %{
             state
             | current_url: redirect_url,
               mint_conn: mint_conn,
               request_ref: request_ref,
               response_status: nil,
               response_headers: [],
               redirect_count: state.redirect_count + 1,
               status: :connecting
           }}

        {:error, reason} ->
          {:stop, reason, %{state | mint_conn: nil, request_ref: nil}}
      end
    else
      nil -> {:stop, :missing_location, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  defp handle_connection_failure(reason, state) do
    if state.buffer_count == 0 and state.url_index + 1 < length(state.urls) do
      Upstream.close(state.mint_conn)
      send(self(), :connect)

      {:noreply,
       %{
         state
         | url_index: state.url_index + 1,
           current_url: nil,
           mint_conn: nil,
           request_ref: nil,
           response_status: nil,
           response_headers: [],
           redirect_count: 0,
           status: :connecting
       }}
    else
      stop_after_error(reason, state)
    end
  end

  defp stop_after_error(reason, state) do
    Health.record_failure(state, reason)
    safe_reason = Upstream.safe_reason(reason)
    Logger.warning("[StreamMux] upstream failed: #{SafeLog.redact_inspect(safe_reason)}")
    Subscribers.notify_error(state, safe_reason)
    {:stop, {:shutdown, :upstream_error}, %{state | status: :error}}
  end

  defp connect_current_url(state) do
    url = Enum.at(state.urls, state.url_index)

    case Upstream.connect(url, state.url_validator, @connect_timeout) do
      {:ok, mint_conn, request_ref} ->
        {:ok,
         %{
           state
           | current_url: url,
             mint_conn: mint_conn,
             request_ref: request_ref,
             status: :connecting
         }}

      {:error, reason} ->
        {:error, reason, state}
    end
  end
end
