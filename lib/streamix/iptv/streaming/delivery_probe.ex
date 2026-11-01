defmodule Streamix.Iptv.Streaming.DeliveryProbe do
  @moduledoc """
  Decides, per item and at play time, how a `direct_client_playback`
  provider's movie or episode is delivered.

  For such providers `container_extension` says nothing reliable: an item
  listed as `mp4` can answer HLS from a CDN this server reaches, while another
  source of the same item redirects to a progressive CDN that refuses this
  server's datacenter address but serves end users. Each item may have
  several sources, selected with `?source=N` on its Xtream URL.

  The probe tries the item's sources in the provider's order (the synced
  `source_ids`, or `fallback_sources` when the sync has not stored any) and
  walks each with `RedirectResolver.final_hop/2` — manual redirects, SSRF on
  every hop, at most five redirects, no body read. The first usable source
  decides:

    * the final hop answers `200`/`206` with an HLS type or an `#EXTM3U`
      body prefix → `{:hls, source_url}`: the HLS gateway serves it, rooted
      at that credential-bearing source URL (server-side only);
    * the final hop is a progressive or refusing host (`200`/`206` media, or
      `401`/`403`) reached through at least one redirect, and its URL passes
      `Streamix.Iptv.Streaming.DirectUrl` (no password, `https`) →
      `{:direct, client_url, extension}`: the client is redirected there;
    * `404`/`410`, `5xx`, a web page, a credential-bearing or unsafe final
      URL, or a transport error → the next source.

  When no source is usable the result is `{:error, :upstream_not_found}` if
  every source answered `404`/`410`, and `{:error, :upstream_unavailable}`
  otherwise.

  ## Live channels

  For a `probe_live_delivery` provider, a channel's single live URL is walked
  the same way. A `200` HLS answer → `{:hls, url}` (the gateway); a `200`
  whose first byte is the MPEG-TS sync byte `0x47` → `:ts` (the existing live
  proxy); any other `200` — some "channels" redirect to a third-party embed
  page — → `{:error, :not_a_stream}`; `404`/`410` → `:upstream_not_found`;
  anything else → `:upstream_unavailable`. A failure is never served.

  Decisions are cached in ETS per provider credentials, item and stream id:
  HLS for `hls_ttl_seconds` (1800), TS for `ts_ttl_seconds` (1800), direct
  for `direct_ttl_seconds` (600, because the final URL embeds an upstream
  token) and failures for `failure_ttl_seconds` (120). Concurrent callers for one item share one
  probe, which runs under the provider's HLS fetch lease and an overall
  `deadline_ms` (20 s). Configuration lives under
  `config :streamix, :xtream_delivery`.

  Nothing here logs a URL, a username or a token.
  """

  use GenServer

  require Logger

  alias Streamix.Iptv.Streaming.{DirectUrl, RedirectResolver, UpstreamPolicy}
  alias Streamix.Iptv.Streaming.XtreamHls.Sessions
  alias Streamix.Iptv.XtreamClient

  @table :xtream_delivery_probe
  @hls_types ~w(application/vnd.apple.mpegurl application/x-mpegurl audio/mpegurl audio/x-mpegurl)
  @page_types ~w(text/html application/json application/xml text/xml)
  @progressive_extensions ~w(mp4 mkv m4v mov avi webm mpg mpeg wmv flv ts)
  @max_waiters 256

  @type decision :: {:hls, String.t()} | {:direct, String.t(), String.t()} | :ts
  @type item_type :: :movie | :episode | :channel

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns the cached or freshly probed delivery for `content` (a movie or an
  episode) of `provider`.
  """
  @spec decide(map(), item_type(), map()) :: {:ok, decision()} | {:error, atom()}
  def decide(provider, type, content) when type in [:movie, :episode, :channel] do
    key = cache_key(provider, type, content)

    case lookup(key) do
      {:hit, result} ->
        result

      :miss ->
        GenServer.call(
          __MODULE__,
          {:probe, key, fn -> probe(provider, type, content) end},
          deadline_ms() + 5_000
        )
    end
  end

  @doc "The cached decision for `content`, or `:miss`; never probes."
  @spec peek(map(), item_type(), map()) :: {:ok, decision()} | {:error, atom()} | :miss
  def peek(provider, type, content) when type in [:movie, :episode, :channel] do
    case lookup(cache_key(provider, type, content)) do
      {:hit, result} -> result
      :miss -> :miss
    end
  end

  @doc "Configuration value under `:xtream_delivery`."
  def config(key, default),
    do: Keyword.get(Application.get_env(:streamix, :xtream_delivery, []), key, default)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{pending: %{}, tasks: %{}}}
  end

  @impl true
  def handle_call({:probe, key, fun}, from, state) do
    case {lookup(key), state.pending[key]} do
      {{:hit, result}, _pending} ->
        {:reply, result, state}

      {:miss, %{waiters: waiters}} when length(waiters) >= @max_waiters ->
        {:reply, {:error, :provider_capacity_exhausted}, state}

      {:miss, %{waiters: waiters}} ->
        {:noreply, put_in(state.pending[key].waiters, [from | waiters])}

      {:miss, nil} ->
        task = Task.Supervisor.async_nolink(Streamix.TaskSupervisor, fun)
        timer = Process.send_after(self(), {:deadline, task.ref}, deadline_ms())
        pending = %{waiters: [from], task: task, timer: timer}

        {:noreply,
         %{
           state
           | pending: Map.put(state.pending, key, pending),
             tasks: Map.put(state.tasks, task.ref, key)
         }}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, finish(state, ref, {:error, :upstream_unavailable})}

  def handle_info({:deadline, ref}, state) do
    if key = state.tasks[ref], do: Task.shutdown(state.pending[key].task, :brutal_kill)
    {:noreply, finish(state, ref, {:error, :upstream_timeout})}
  end

  def handle_info(:cleanup, state) do
    now = now()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_cleanup()
    {:noreply, state}
  end

  defp finish(state, ref, result) do
    case Map.pop(state.tasks, ref) do
      {nil, _tasks} ->
        state

      {key, tasks} ->
        {pending, pending_map} = Map.pop(state.pending, key)
        Process.cancel_timer(pending.timer)
        result = normalize(result)
        :ets.insert(@table, {key, result, now() + ttl(result)})
        Enum.each(pending.waiters, &GenServer.reply(&1, result))
        %{state | tasks: tasks, pending: pending_map}
    end
  end

  defp normalize({:ok, {:hls, _url}} = result), do: result
  defp normalize({:ok, {:direct, _url, _extension}} = result), do: result
  defp normalize({:ok, :ts} = result), do: result
  defp normalize({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize(_other), do: {:error, :upstream_unavailable}

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, result, expires_at}] -> if expires_at > now(), do: {:hit, result}, else: :miss
      [] -> :miss
    end
  end

  # The credentials are part of the key, so a provider whose URL or password
  # changed never reuses a decision rooted at its old account.
  defp cache_key(provider, type, content) do
    credentials =
      :erlang.phash2(
        {provider.url, provider.username, provider.password,
         UpstreamPolicy.domain_policy(provider)}
      )

    {provider.id, credentials, type, stream_id(type, content)}
  end

  defp ttl({:ok, {:hls, _url}}), do: config(:hls_ttl_seconds, 1_800)
  defp ttl({:ok, {:direct, _url, _extension}}), do: config(:direct_ttl_seconds, 600)
  defp ttl({:ok, :ts}), do: config(:ts_ttl_seconds, 1_800)
  defp ttl(_failure), do: config(:failure_ttl_seconds, 120)

  # --- The probe itself (runs in a supervised task) ---

  # A live channel has one URL and no sources. Its answer is either an HLS
  # playlist (the gateway), a TS byte stream (the live proxy), or not a
  # stream at all — some "channels" redirect to a third-party embed page —
  # which is reported unavailable and never served.
  defp probe(provider, :channel, channel) do
    url =
      XtreamClient.live_stream_url(
        provider.url,
        provider.username,
        provider.password,
        channel.stream_id
      )

    result =
      case with_lease(provider.id, fn ->
             RedirectResolver.final_hop(url, final_hop_options(provider))
           end) do
        {:ok, hop} -> classify_live(hop, url)
        {:error, reason} -> {:error, transport_reason(reason)}
      end

    with {:error, reason} <- result do
      Logger.info(
        "[DeliveryProbe] live channel unavailable provider=#{provider.id} " <>
          "content=#{Streamix.SafeLog.content_ref({:channel, channel.id})} reason=#{inspect(reason)}"
      )

      result
    end
  end

  defp probe(provider, type, content) do
    content
    |> candidates()
    |> Enum.reduce_while([], fn source, failures ->
      case probe_source(provider, type, content, source) do
        {:ok, decision} -> {:halt, {:ok, decision}}
        {:skip, reason} -> {:cont, [reason | failures]}
      end
    end)
    |> case do
      {:ok, decision} ->
        {:ok, decision}

      failures ->
        Logger.info(
          "[DeliveryProbe] no usable source provider=#{provider.id} type=#{type} " <>
            "content=#{Streamix.SafeLog.content_ref({type, content.id})} " <>
            "reasons=#{inspect(Enum.reverse(failures))}"
        )

        {:error, failure_reason(failures)}
    end
  end

  defp candidates(content) do
    ids =
      case Map.get(content, :source_ids) do
        [_ | _] = ids -> ids
        _ -> config(:fallback_sources, [1, 2, 3])
      end

    Enum.take(ids, config(:max_sources, 6))
  end

  defp probe_source(provider, type, content, source) do
    url = source_url(provider, type, content, source)

    case with_lease(provider.id, fn ->
           RedirectResolver.final_hop(url, final_hop_options(provider))
         end) do
      {:ok, hop} -> classify(hop, url, provider, content)
      {:error, reason} -> {:skip, transport_reason(reason)}
    end
  end

  defp classify(%{status: status} = hop, source_url, provider, content)
       when status in [200, 206] do
    cond do
      hls?(hop) -> {:ok, {:hls, source_url}}
      hop.content_type in @page_types -> {:skip, :not_media}
      true -> direct(hop, provider, content)
    end
  end

  defp classify(%{status: status} = hop, _source_url, provider, content)
       when status in [401, 403],
       do: direct(hop, provider, content)

  defp classify(%{status: status}, _source_url, _provider, _content) when status in [404, 410],
    do: {:skip, :upstream_not_found}

  defp classify(_hop, _source_url, _provider, _content), do: {:skip, :upstream_unavailable}

  # The panel's own URL carries the password, so only a hop reached through
  # a redirect can ever be handed out.
  defp direct(%{redirects: 0}, _provider, _content), do: {:skip, :credentials_in_url}

  defp direct(hop, provider, content) do
    case DirectUrl.prepare(hop.url, provider.password) do
      {:ok, client_url} -> {:ok, {:direct, client_url, extension(client_url, content)}}
      {:error, reason} -> {:skip, reason}
    end
  end

  defp hls?(%{content_type: type, prefix: prefix}),
    do: type in @hls_types or String.starts_with?(prefix, "#EXTM3U")

  defp classify_live(%{status: status} = hop, url) when status in [200, 206] do
    cond do
      hls?(hop) -> {:ok, {:hls, url}}
      transport_stream?(hop) -> {:ok, :ts}
      true -> {:error, :not_a_stream}
    end
  end

  defp classify_live(%{status: status}, _url) when status in [404, 410],
    do: {:error, :upstream_not_found}

  defp classify_live(_hop, _url), do: {:error, :upstream_unavailable}

  # The body decides when there is one (MPEG-TS packets start with 0x47);
  # the declared type only when the first chunk was empty.
  defp transport_stream?(%{prefix: <<0x47, _::binary>>}), do: true
  defp transport_stream?(%{prefix: "", content_type: "video/mp2t"}), do: true
  defp transport_stream?(_hop), do: false

  # The client picks its engine from the Streamix URL suffix, so it names
  # the container the client will receive: the final URL's own extension
  # when it is a known progressive one, else the catalogue's.
  defp extension(client_url, content) do
    from_url =
      case URI.new(client_url) do
        {:ok, %URI{path: path}} when is_binary(path) ->
          path |> Path.extname() |> String.trim_leading(".") |> String.downcase()

        _ ->
          ""
      end

    from_catalog = content |> Map.get(:container_extension) |> to_string() |> String.downcase()

    cond do
      from_url in @progressive_extensions -> from_url
      from_catalog in @progressive_extensions -> from_catalog
      true -> "mp4"
    end
  end

  defp source_url(provider, type, content, source) do
    extension = content |> Map.get(:container_extension) |> plain_extension()
    base = stream_url(provider, type, stream_id(type, content), extension)
    if is_integer(source), do: base <> "?source=#{source}", else: base
  end

  defp stream_url(provider, :movie, stream_id, extension),
    do:
      XtreamClient.movie_stream_url(
        provider.url,
        provider.username,
        provider.password,
        stream_id,
        extension
      )

  defp stream_url(provider, :episode, stream_id, extension),
    do:
      XtreamClient.episode_stream_url(
        provider.url,
        provider.username,
        provider.password,
        stream_id,
        extension
      )

  defp plain_extension(value) do
    value = value |> to_string() |> String.trim_leading(".") |> String.downcase()
    if Regex.match?(~r/^[a-z0-9]{1,8}$/, value), do: value, else: "mp4"
  end

  defp stream_id(:movie, content), do: content.stream_id
  defp stream_id(:episode, content), do: content.episode_id
  defp stream_id(:channel, content), do: content.stream_id

  defp final_hop_options(provider) do
    [
      domain_policy: UpstreamPolicy.domain_policy(provider),
      headers: [{"user-agent", UpstreamPolicy.user_agent()}],
      req_options:
        Keyword.merge(
          [receive_timeout: 6_000, connect_options: [timeout: 4_000]],
          config(:http_options, [])
        )
    ]
  end

  defp with_lease(provider_id, fun) do
    case Sessions.acquire(provider_id) do
      {:ok, lease} ->
        try do
          fun.()
        after
          Sessions.release(lease)
        end

      error ->
        error
    end
  end

  defp transport_reason(reason)
       when reason in [:unsafe_url, :too_many_redirects, :provider_capacity_exhausted],
       do: reason

  defp transport_reason(:missing_location), do: :upstream_unavailable
  defp transport_reason(%{__struct__: _module, reason: :timeout}), do: :upstream_timeout
  defp transport_reason(_reason), do: :upstream_unavailable

  defp failure_reason([]), do: :upstream_unavailable

  defp failure_reason(failures) do
    if Enum.all?(failures, &(&1 == :upstream_not_found)),
      do: :upstream_not_found,
      else: :upstream_unavailable
  end

  defp deadline_ms, do: config(:deadline_ms, 20_000)
  defp now, do: System.monotonic_time(:second)
  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, 300_000)
end
