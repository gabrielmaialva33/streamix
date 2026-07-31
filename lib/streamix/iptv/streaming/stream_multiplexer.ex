defmodule Streamix.Iptv.StreamMultiplexer do
  @moduledoc """
  Fans one live upstream connection out to multiple downstream processes.

  Subscribers use explicit demand. Every subscriber has a bounded private
  queue, so one slow client cannot grow the multiplexer mailbox indefinitely
  or stall other viewers. The upstream connection owns exactly one
  `ProviderRuntime` lease regardless of subscriber count.
  """

  use GenServer, restart: :transient

  require Logger

  alias Streamix.Iptv.Channels
  alias Streamix.Iptv.Streaming.{ProviderRuntime, UpstreamPolicy}
  alias Streamix.Iptv.StreamMultiplexerSupervisor
  alias Streamix.SafeLog
  alias Streamix.Security.UrlValidator

  @connect_timeout 10_000
  @default_idle_timeout 2_000
  @default_buffer_size 30
  @max_buffer_bytes 5 * 1_024 * 1_024
  @default_subscriber_buffer_bytes 5 * 1_024 * 1_024
  @max_redirects 5
  @redirect_statuses [301, 302, 303, 307, 308]
  @forwardable_headers ~w(content-type accept-ranges etag last-modified)

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
      |> Keyword.put(:urls, normalize_urls(urls))

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
    {state, _subscriber} = put_subscriber(state, pid)
    state = cancel_idle_timer(state)

    case ensure_upstream_started(state) do
      {:ok, state} ->
        {:reply, {:ok, subscription(state)}, state}

      {:error, reason, state} ->
        state = remove_subscriber(state, pid)
        {:reply, {:error, reason}, maybe_start_idle_timer(state)}
    end
  end

  @impl true
  def handle_cast({:demand, pid}, state) do
    {:noreply,
     update_subscriber(state, pid, fn subscriber ->
       deliver_with_demand(pid, subscriber, 1, state)
     end)}
  end

  def handle_cast({:unsubscribe, pid}, state) do
    state = state |> remove_subscriber(pid) |> maybe_start_idle_timer()
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
        state = state |> remove_subscriber(pid, false) |> maybe_start_idle_timer()
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
    close_upstream(state)
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

  defp put_subscriber(state, pid) do
    case Map.get(state.subscribers, pid) do
      nil ->
        subscriber = %{
          monitor_ref: Process.monitor(pid),
          demand: 0,
          queue: :queue.new(),
          queued_bytes: 0
        }

        {%{state | subscribers: Map.put(state.subscribers, pid, subscriber)}, subscriber}

      subscriber ->
        {state, subscriber}
    end
  end

  defp update_subscriber(state, pid, fun) do
    case Map.fetch(state.subscribers, pid) do
      {:ok, subscriber} ->
        case fun.(subscriber) do
          {:keep, subscriber} ->
            %{state | subscribers: Map.put(state.subscribers, pid, subscriber)}

          :drop ->
            remove_subscriber(state, pid)
        end

      :error ->
        state
    end
  end

  defp remove_subscriber(state, pid, demonitor? \\ true) do
    case Map.pop(state.subscribers, pid) do
      {nil, _subscribers} ->
        state

      {%{monitor_ref: monitor_ref}, subscribers} ->
        if demonitor?, do: Process.demonitor(monitor_ref, [:flush])
        %{state | subscribers: subscribers}
    end
  end

  defp deliver_with_demand(pid, subscriber, increment, state) do
    subscriber
    |> Map.update!(:demand, &min(&1 + increment, 1))
    |> deliver_pending(pid, state)
  end

  defp deliver_pending(%{demand: demand} = subscriber, _pid, _state) when demand <= 0,
    do: {:keep, subscriber}

  defp deliver_pending(subscriber, pid, _state) do
    case :queue.out(subscriber.queue) do
      {:empty, _queue} ->
        {:keep, subscriber}

      {{:value, {:chunk, chunk, size}}, queue} ->
        send(pid, {:stream_mux, self(), {:chunk, chunk}})

        {:keep,
         %{
           subscriber
           | demand: subscriber.demand - 1,
             queue: queue,
             queued_bytes: subscriber.queued_bytes - size
         }}

      {{:value, {:terminal, event}}, _queue} ->
        send(pid, {:stream_mux, self(), event})
        :drop
    end
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
    response_headers = filter_response_headers(headers)

    state = %{state | response_headers: response_headers, status: :streaming}
    notify_ready(state)
    {:ok, state}
  end

  defp process_response({:data, _ref, chunk}, state) when is_binary(chunk) do
    state = state |> record_first_success() |> push_chunk(chunk)
    {:ok, state}
  end

  defp process_response({:done, _ref}, state) do
    state = enqueue_terminal(state, :done)
    close_upstream(state)
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
    with location when is_binary(location) <- header_value(headers, "location"),
         redirect_url <- resolve_url(state.current_url, location),
         :ok <- state.url_validator.(redirect_url) do
      close_upstream(state)

      case connect_upstream(redirect_url, state.url_validator) do
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
      close_upstream(state)
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
    record_failure(state, reason)
    safe_reason = safe_reason(reason)
    Logger.warning("[StreamMux] upstream failed: #{SafeLog.redact_inspect(safe_reason)}")
    notify_error(state, safe_reason)
    {:stop, {:shutdown, :upstream_error}, %{state | status: :error}}
  end

  defp connect_current_url(state) do
    url = Enum.at(state.urls, state.url_index)

    case connect_upstream(url, state.url_validator) do
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

  defp connect_upstream(nil, _validator), do: {:error, :missing_upstream_url}

  defp connect_upstream(url, validator) do
    with :ok <- validator.(url),
         %URI{host: host} = uri when is_binary(host) <- URI.parse(url) do
      scheme = if uri.scheme == "https", do: :https, else: :http
      port = uri.port || default_port(scheme)

      transport_opts =
        if scheme == :https,
          do: [cacerts: :public_key.cacerts_get(), timeout: @connect_timeout],
          else: [timeout: @connect_timeout]

      headers = [
        {"host", host},
        {"user-agent", UpstreamPolicy.user_agent()},
        {"accept", "*/*"},
        {"connection", "keep-alive"}
      ]

      with {:ok, mint_conn} <-
             Mint.HTTP.connect(scheme, host, port, transport_opts: transport_opts),
           {:ok, mint_conn, request_ref} <-
             Mint.HTTP.request(mint_conn, "GET", request_path(uri), headers, nil) do
        {:ok, mint_conn, request_ref}
      else
        {:error, mint_conn, reason} ->
          close_mint_conn(mint_conn)
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_upstream_url}
    end
  end

  defp notify_ready(state) do
    backlog = :queue.to_list(state.buffer)

    Enum.each(state.subscribers, fn {pid, _subscriber} ->
      send(pid, {
        :stream_mux,
        self(),
        {:ready, state.response_status || 200, state.response_headers, backlog}
      })
    end)
  end

  defp notify_error(state, reason) do
    Enum.each(state.subscribers, fn {pid, _subscriber} ->
      send(pid, {:stream_mux, self(), {:error, reason}})
    end)
  end

  defp push_chunk(state, chunk) do
    state = put_ring_buffer(state, chunk)

    subscribers =
      Enum.reduce(state.subscribers, %{}, fn {pid, subscriber}, subscribers ->
        case enqueue_subscriber(pid, subscriber, chunk, state) do
          {:keep, subscriber} -> Map.put(subscribers, pid, subscriber)
          :drop -> subscribers
        end
      end)

    %{state | subscribers: subscribers}
    |> maybe_start_idle_timer()
  end

  defp enqueue_subscriber(pid, subscriber, chunk, state) do
    size = byte_size(chunk)
    queued_bytes = subscriber.queued_bytes + size

    if queued_bytes > state.subscriber_buffer_bytes do
      send(pid, {:stream_mux, self(), {:error, :slow_consumer}})
      Process.demonitor(subscriber.monitor_ref, [:flush])
      :drop
    else
      subscriber = %{
        subscriber
        | queue: :queue.in({:chunk, chunk, size}, subscriber.queue),
          queued_bytes: queued_bytes
      }

      deliver_pending(subscriber, pid, state)
    end
  end

  defp enqueue_terminal(state, event) do
    subscribers =
      Enum.reduce(state.subscribers, %{}, fn {pid, subscriber}, subscribers ->
        subscriber = %{subscriber | queue: :queue.in({:terminal, event}, subscriber.queue)}

        case deliver_pending(subscriber, pid, state) do
          {:keep, subscriber} ->
            Map.put(subscribers, pid, subscriber)

          :drop ->
            Process.demonitor(subscriber.monitor_ref, [:flush])
            subscribers
        end
      end)

    %{state | subscribers: subscribers}
    |> maybe_start_idle_timer()
  end

  defp put_ring_buffer(state, chunk) do
    buffer = :queue.in(chunk, state.buffer)
    count = state.buffer_count + 1
    bytes = state.buffer_bytes + byte_size(chunk)

    {buffer, count, bytes} = trim_buffer(buffer, count, bytes, state.buffer_size)

    %{state | buffer: buffer, buffer_count: count, buffer_bytes: bytes}
  end

  defp trim_buffer(buffer, count, bytes, max_count)
       when count > max_count or (count > 1 and bytes > @max_buffer_bytes) do
    {{:value, old_chunk}, buffer} = :queue.out(buffer)
    trim_buffer(buffer, count - 1, bytes - byte_size(old_chunk), max_count)
  end

  defp trim_buffer(buffer, count, bytes, _max_count), do: {buffer, count, bytes}

  defp record_first_success(%{health_recorded?: true} = state), do: state

  defp record_first_success(state) do
    latency = System.monotonic_time(:millisecond) - state.started_at
    ProviderRuntime.record_success(state.provider_id, :live, latency)
    maybe_mark_channel_alive(state.content_id)
    %{state | health_recorded?: true}
  end

  defp record_failure(state, {:unexpected_status, status}) when status in [404, 410] do
    maybe_mark_channel_dead(state.content_id)
  end

  defp record_failure(state, reason) do
    ProviderRuntime.record_failure(state.provider_id, :live, reason)
  end

  defp maybe_mark_channel_alive(content_id) when is_integer(content_id),
    do: safe_channel_update(fn -> Channels.mark_alive(content_id) end)

  defp maybe_mark_channel_alive(_content_id), do: :ok

  defp maybe_mark_channel_dead(content_id) when is_integer(content_id),
    do: safe_channel_update(fn -> Channels.mark_dead(content_id) end)

  defp maybe_mark_channel_dead(_content_id), do: :ok

  defp safe_channel_update(fun) do
    fun.()
  rescue
    error ->
      Logger.warning("[StreamMux] channel liveness update failed: #{Exception.message(error)}")
      :ok
  end

  defp filter_response_headers(headers) do
    Enum.filter(headers, fn {name, _value} -> String.downcase(name) in @forwardable_headers end)
  end

  defp header_value(headers, target) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == target, do: value
    end)
  end

  defp close_upstream(%{mint_conn: nil}), do: :ok
  defp close_upstream(%{mint_conn: mint_conn}), do: close_mint_conn(mint_conn)

  defp close_mint_conn(nil), do: :ok

  defp close_mint_conn(mint_conn) do
    Mint.HTTP.close(mint_conn)
    :ok
  rescue
    _ -> :ok
  end

  defp cancel_idle_timer(%{idle_timer: nil} = state), do: state

  defp cancel_idle_timer(%{idle_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | idle_timer: nil}
  end

  defp maybe_start_idle_timer(state) do
    if map_size(state.subscribers) == 0 and is_nil(state.idle_timer) do
      %{state | idle_timer: Process.send_after(self(), :idle_timeout, state.idle_timeout)}
    else
      state
    end
  end

  defp safe_reason({:unexpected_status, status}), do: {:unexpected_status, status}
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(%{__struct__: module}), do: module
  defp safe_reason(_reason), do: :upstream_error

  defp normalize_urls(url) when is_binary(url), do: [url]

  defp normalize_urls(urls) when is_list(urls) do
    urls |> Enum.filter(&is_binary/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
  end

  defp normalize_urls(_urls), do: []

  defp default_port(:https), do: 443
  defp default_port(:http), do: 80

  defp request_path(uri) do
    path = uri.path || "/"
    if uri.query, do: "#{path}?#{uri.query}", else: path
  end

  defp resolve_url(base_url, location) do
    base_url |> URI.parse() |> URI.merge(location) |> URI.to_string()
  end
end
