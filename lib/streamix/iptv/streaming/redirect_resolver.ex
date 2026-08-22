defmodule Streamix.Iptv.Streaming.RedirectResolver do
  @moduledoc """
  Cache for IPTV redirect-chain resolution.

  IPTV upstreams (`iptv`, `vauth*`) often answer with a 302 chain that
  takes 10-20s to walk on the first hit (cold DNS, fresh TLS, token
  validation). The result, however, stays valid for ~1 minute, so the
  *second* request for the same content is essentially free.

  This GenServer caches the final resolved URL per upstream URL key,
  with a single-flight lock so concurrent callers piggy-back on a
  resolution already in flight instead of starting a new one. The
  expected use is:

    1. `PlayerLive.mount/3` calls `prewarm_async/2` as soon as the
       socket connects — the resolution starts running in background
       while the browser is still parsing HTML and bootstrapping the
       LiveView.
    2. The `<video>` element fires `GET /api/stream/proxy?token=…`
       ~500ms-1.5s later. `StreamController` calls `resolve/2` for
       the same upstream URL: if the prewarm already finished, it is
       a cache hit (~5ms). If still in flight, the call blocks on the
       single-flight placeholder until the in-flight task posts the
       result, instead of starting a parallel duplicate.

  Errors are cached for a short window (`@err_ttl_seconds`) so a
  transient upstream blip is recoverable on the next player retry
  without trampling the upstream with a tight retry loop.
  """

  use GenServer
  require Logger

  alias Streamix.Iptv.Streaming.UpstreamPolicy
  alias Streamix.SafeLog

  @table :stream_redirect_cache
  @ok_ttl_seconds 60
  @err_ttl_seconds 3
  # The placeholder lives long enough to cover a worst-case 3-hop vauth
  # chain (each hop ~8s) plus a small safety margin.
  @placeholder_ttl_seconds 35
  @cleanup_interval_ms 60_000
  @max_redirects 5
  @poll_interval_ms 50
  @redis :streamix_redis
  @redis_prefix "stream_redirect:"
  @full_cache_scope :full
  @credential_exchange_cache_scope :credential_exchange
  @first_redirect_cache_scope :prewarm_first_redirect
  @uri_path_characters ~c"/:@!$&'()*+,;=%"

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Resolves the redirect chain for `url` and returns the final URL.

  Returns `{:ok, final_url}` or `{:error, reason}`. Identical results
  for the same `url` are served from cache for #{@ok_ttl_seconds}s.

  Options:

    * `:cache_scope` — separates cached results produced by different
      resolution policies. The default full-chain policy uses `:full`.
      A custom `:stop_fn` without an explicit scope is deliberately
      uncached so it can never poison the full-chain result.
    * `:stop_fn` — `fn next_url -> boolean`. Stop walking the chain when
      this returns `true` for the next URL (used to short-circuit at the
      first hop where IPTV credentials have been swapped for a
      single-use token, so the slow part of the chain runs in the nginx
      upstream proxy instead of the BEAM).
    * `:req_options` — extra options merged into the underlying `Req`
      call (mostly useful in tests to point at a stub server).
  """
  def resolve(url, opts \\ []) when is_binary(url) do
    case cache_policy(opts) do
      :uncached ->
        resolve_uncached(url, opts)

      {:cached, scope} ->
        case lookup(url, scope) do
          {:hit, result} ->
            result

          :miss ->
            do_resolve(url, opts, scope)

          :resolving ->
            # Someone else owns the resolution — wait for their result.
            wait_for_resolution(url, opts, scope)
        end
    end
  end

  @doc """
  Resolves only far enough to exchange credentials embedded in an Xtream
  path for the first credential-free redirect target.

  This policy has its own cache scope so its intentionally partial result
  can never be mistaken for a full-chain resolution.
  """
  def resolve_for_proxy(url, opts \\ []) when is_binary(url) and is_list(opts) do
    if credentials_in_url?(url) do
      resolve(url, credential_exchange_options(opts))
    else
      resolve(url, opts)
    end
  end

  @doc """
  Asynchronously prewarms the cache for `url` so a subsequent
  `resolve/2` for the same URL hits the cache immediately. Non-blocking.

  If a resolution is already in flight or cached, this is a no-op.
  """
  def prewarm_async(url, opts \\ []) when is_binary(url) do
    case cache_policy(opts) do
      :uncached ->
        Task.Supervisor.start_child(Streamix.TaskSupervisor, fn ->
          _ = resolve_uncached(url, opts)
        end)

        :ok

      {:cached, scope} ->
        case lookup(url, scope) do
          {:hit, _} ->
            :ok

          :resolving ->
            :ok

          :miss ->
            Task.Supervisor.start_child(Streamix.TaskSupervisor, fn ->
              _ = resolve(url, opts)
            end)

            :ok
        end
    end
  end

  @doc """
  Prewarms the exact same credential-exchange policy used by
  `resolve_for_proxy/2`. Credential-free URLs use an isolated, first-hop
  prewarm scope and therefore cannot contaminate the default full scope.
  """
  def prewarm_for_proxy_async(url, opts \\ []) when is_binary(url) and is_list(opts) do
    if credentials_in_url?(url) do
      prewarm_async(url, credential_exchange_options(opts))
    else
      prewarm_async(
        url,
        opts
        |> Keyword.put(:cache_scope, @first_redirect_cache_scope)
        |> Keyword.put(:stop_fn, &stop_at_first_redirect?/1)
      )
    end
  end

  @doc """
  Read-only lookup. Returns `{:ok, final_url}` on a hot cache hit
  (ETS or Redis L2), `:miss` otherwise. Never starts a resolution.

  Used by `PlayerHelpers.resolve_stream_url/4` to decide between
  signing a direct URL pointing at the source proxy (cache hit → fast
  path) and falling back to the Phoenix `/api/stream/proxy` token
  redirect (cache miss → wait-and-redirect path).
  """
  @spec peek(String.t(), keyword()) :: {:ok, String.t()} | :miss
  def peek(url, opts \\ []) when is_binary(url) and is_list(opts) do
    case Keyword.keys(opts) -- [:cache_scope] do
      [] -> :ok
      unsupported -> raise ArgumentError, "unsupported peek options: #{inspect(unsupported)}"
    end

    scope = Keyword.get(opts, :cache_scope, @full_cache_scope)

    case lookup(url, scope) do
      {:hit, {:ok, _final} = ok} -> ok
      _ -> :miss
    end
  end

  @doc false
  def cache_table, do: @table

  @doc false
  def clear_cache do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_cleanup()

    Logger.info(
      "RedirectResolver started (ok_ttl=#{@ok_ttl_seconds}s err_ttl=#{@err_ttl_seconds}s lock=#{@placeholder_ttl_seconds}s)"
    )

    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    purge_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  # Internals

  defp lookup(url, scope) do
    key = cache_key(url, scope)
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, {:result, result}, expires_at}] when expires_at > now ->
        {:hit, result}

      [{^key, :resolving, expires_at}] when expires_at > now ->
        :resolving

      _ ->
        # ETS miss — check the Redis L2 cache. This pays off after
        # container restarts: the in-memory ETS table is fresh, but
        # Redis still holds resolutions from before the restart.
        case redis_get(key) do
          {:ok, {result, ttl_seconds}} ->
            promote_to_ets(key, result, ttl_seconds)
            {:hit, result}

          :miss ->
            :miss
        end
    end
  end

  defp promote_to_ets(key, result, ttl_seconds) do
    expires_at = System.system_time(:second) + max(ttl_seconds, 1)
    :ets.insert(@table, {key, {:result, result}, expires_at})
  end

  defp do_resolve(url, opts, scope) do
    key = cache_key(url, scope)
    placeholder_expires = System.system_time(:second) + @placeholder_ttl_seconds

    if :ets.insert_new(@table, {key, :resolving, placeholder_expires}) do
      # We won the lock — perform the resolution and publish the result.
      result =
        try do
          walk_chain_from_policy(url, opts, scope)
        catch
          kind, reason ->
            Logger.error(
              "RedirectResolver: walk_chain crashed (#{kind}): " <>
                "#{SafeLog.redact_inspect(reason)} for #{sanitize(url)}"
            )

            {:error, {:resolver_crashed, kind, reason}}
        end

      cache_result(key, result)
      result
    else
      # Lost the race — another caller is already resolving.
      wait_for_resolution(url, opts, scope)
    end
  end

  defp wait_for_resolution(url, opts, scope) do
    key = cache_key(url, scope)
    deadline = System.monotonic_time(:millisecond) + (@placeholder_ttl_seconds + 1) * 1000
    poll_until_resolved(key, url, opts, scope, deadline)
  end

  defp poll_until_resolved(key, url, opts, scope, deadline) do
    Process.sleep(@poll_interval_ms)

    case :ets.lookup(@table, key) do
      [{^key, {:result, result}, _}] ->
        result

      [{^key, :resolving, _}] ->
        if System.monotonic_time(:millisecond) < deadline do
          poll_until_resolved(key, url, opts, scope, deadline)
        else
          # Owner appears stuck — claim the slot and resolve ourselves.
          Logger.warning("RedirectResolver: lock holder timed out for #{sanitize(url)}, retrying")

          :ets.delete(@table, key)
          do_resolve(url, opts, scope)
        end

      _ ->
        # Slot was purged while we were polling. Try again from scratch.
        do_resolve(url, opts, scope)
    end
  end

  defp resolve_uncached(url, opts) do
    try do
      walk_chain(url, opts)
    catch
      kind, reason ->
        Logger.error(
          "RedirectResolver: walk_chain crashed (#{kind}): " <>
            "#{SafeLog.redact_inspect(reason)} for #{sanitize(url)}"
        )

        {:error, {:resolver_crashed, kind, reason}}
    end
  end

  defp cache_result(key, {:ok, final_url} = result) do
    # Defensive: never cache a "final" URL that points back at our own
    # source proxy. The proxy would then proxy_pass to itself, creating an
    # endless loop / 504. This shouldn't happen under normal walk_chain
    # semantics, but the L2 Redis cache survives deploys, so discard the
    # entry instead of keeping a poisoned result.
    if loops_back_to_self?(final_url) do
      Logger.warning(
        "RedirectResolver: refusing to cache self-referential final URL #{sanitize(final_url)}"
      )

      result
    else
      expires_at = System.system_time(:second) + @ok_ttl_seconds
      :ets.insert(@table, {key, {:result, result}, expires_at})
      redis_set_async(key, result, @ok_ttl_seconds)
      result
    end
  end

  defp cache_result(key, {:error, _reason} = result) do
    expires_at = System.system_time(:second) + @err_ttl_seconds
    :ets.insert(@table, {key, {:result, result}, expires_at})
    redis_set_async(key, result, @err_ttl_seconds)
    result
  end

  defp loops_back_to_self?(url) when is_binary(url) do
    base = Application.get_env(:streamix, :stream_proxy_url)

    case base do
      base when is_binary(base) and base != "" -> String.starts_with?(url, base)
      _ -> false
    end
  end

  # Redis I/O — best-effort. The local ETS layer is authoritative for
  # this process; Redis is just a "warm start" pool that survives
  # container restarts. Any Redis hiccup is logged at debug level and
  # does not affect resolution latency.

  # Values under this private prefix are written exclusively by
  # redis_set_async/3 below. :safe prevents constructing executable or
  # unknown runtime terms if Redis contents are corrupted.
  # sobelow_skip ["Misc.BinToTerm"]
  defp redis_get(key) do
    if Process.whereis(@redis) do
      full_key = @redis_prefix <> key

      try do
        case Redix.pipeline(@redis, [["GET", full_key], ["TTL", full_key]]) do
          {:ok, [nil, _]} ->
            :miss

          {:ok, [encoded, ttl]} when is_binary(encoded) and is_integer(ttl) and ttl > 0 ->
            {:ok, {:erlang.binary_to_term(encoded, [:safe]), ttl}}

          _ ->
            :miss
        end
      rescue
        _ -> :miss
      catch
        :exit, _ -> :miss
      end
    else
      :miss
    end
  end

  defp redis_set_async(key, result, ttl_seconds) do
    if Process.whereis(@redis) do
      full_key = @redis_prefix <> key
      payload = :erlang.term_to_binary(result)

      Task.Supervisor.start_child(Streamix.TaskSupervisor, fn ->
        try do
          Redix.command(@redis, ["SETEX", full_key, Integer.to_string(ttl_seconds), payload])
        rescue
          e -> Logger.debug("RedirectResolver: Redis SETEX failed: #{SafeLog.redact_inspect(e)}")
        catch
          :exit, reason ->
            Logger.debug("RedirectResolver: Redis exit: #{SafeLog.redact_inspect(reason)}")
        end
      end)
    end

    :ok
  end

  defp cache_key(url, scope) do
    :crypto.hash(:sha256, :erlang.term_to_binary({scope, url}))
    |> Base.encode16(case: :lower)
  end

  defp cache_policy(opts) do
    case Keyword.fetch(opts, :cache_scope) do
      {:ok, scope} ->
        {:cached, scope}

      :error ->
        if Keyword.has_key?(opts, :stop_fn), do: :uncached, else: {:cached, @full_cache_scope}
    end
  end

  defp walk_chain_from_policy(url, opts, scope) do
    case resolution_start_url(url, opts, scope) do
      ^url ->
        walk_chain(url, opts)

      prewarmed_url ->
        case do_walk(prewarmed_url, 0, opts) do
          {:error, _reason} ->
            # A short-lived prewarmed token may expire or point at a dead
            # cluster node. Retry from the credential-bearing origin so the
            # provider can issue a fresh token before publishing an error.
            walk_chain(url, opts)

          result ->
            result
        end
    end
  end

  defp resolution_start_url(url, opts, @full_cache_scope) do
    if Keyword.has_key?(opts, :stop_fn) do
      url
    else
      case prewarmed_result(url) do
        {:ok, next_url} when is_binary(next_url) -> next_url
        _ -> url
      end
    end
  end

  defp resolution_start_url(url, _opts, _scope), do: url

  defp prewarmed_result(url) do
    {scope, opts} = prewarm_policy(url)

    case lookup(url, scope) do
      {:hit, result} -> result
      :resolving -> wait_for_resolution(url, opts, scope)
      :miss -> :miss
    end
  end

  defp prewarm_policy(url) do
    if credentials_in_url?(url) do
      {@credential_exchange_cache_scope, credential_exchange_options([])}
    else
      {@first_redirect_cache_scope,
       [cache_scope: @first_redirect_cache_scope, stop_fn: &stop_at_first_redirect?/1]}
    end
  end

  defp credential_exchange_options(opts) do
    opts
    |> Keyword.put(:cache_scope, @credential_exchange_cache_scope)
    |> Keyword.put(:stop_fn, &credentials_exchanged?/1)
  end

  defp stop_at_first_redirect?(_next_url), do: true
  defp credentials_exchanged?(next_url), do: not credentials_in_url?(next_url)

  defp credentials_in_url?(url) do
    case URI.parse(url).path do
      nil -> false
      path -> Regex.match?(~r{/(live|movie|series)/[^/]+/[^/]+/}, path)
    end
  end

  defp purge_expired do
    now = System.system_time(:second)
    spec = [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}]
    :ets.select_delete(@table, spec)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  # Walk the redirect chain with provider-cluster failover. Some IPTV
  # providers (looking at you) round-robin redirects
  # across a cluster of vauth/deliver IPs, and 30-50% of those IPs may
  # be dead at any given moment. If we just take the first redirect and
  # cache it, the user gets stuck behind a dead IP for the cache TTL.
  #
  # Strategy: if any hop times out / refuses connection / returns 5xx,
  # we restart the chain from the original URL, hoping the provider
  # routes to a different IP. Up to @retry_attempts retries.
  @retry_attempts 4

  defp walk_chain(url, opts), do: walk_chain(url, opts, 1)

  defp walk_chain(url, _opts, attempt) when attempt > @retry_attempts do
    Logger.warning(
      "RedirectResolver: giving up after #{@retry_attempts} attempts for #{sanitize(url)}"
    )

    {:error, :provider_unreachable}
  end

  defp walk_chain(url, opts, attempt) do
    case do_walk(url, 0, opts) do
      {:ok, _final} = ok ->
        ok

      {:error, reason} ->
        if retryable?(reason) and attempt < @retry_attempts do
          Logger.info(
            "RedirectResolver: hop failed (#{SafeLog.redact_inspect(reason)}), " <>
              "retrying chain (attempt #{attempt + 1}/#{@retry_attempts})"
          )

          walk_chain(url, opts, attempt + 1)
        else
          {:error, reason}
        end
    end
  end

  defp retryable?(%Req.TransportError{reason: :timeout}), do: true
  defp retryable?(%Req.TransportError{reason: :closed}), do: true
  defp retryable?(%Req.TransportError{reason: :econnrefused}), do: true
  defp retryable?(%Req.TransportError{reason: :ehostunreach}), do: true
  defp retryable?(%Req.TransportError{reason: :nxdomain}), do: true
  defp retryable?({:unexpected_status, status}) when status in [502, 503, 504], do: true
  defp retryable?(_), do: false

  defp do_walk(_url, count, _opts) when count > @max_redirects do
    {:error, :too_many_redirects}
  end

  defp do_walk(url, count, opts) do
    case Req.get(url, build_req_opts(opts)) do
      {:ok, %{status: status, headers: headers}} when status in [301, 302, 303, 307, 308] ->
        follow_redirect(url, headers, count, opts)

      {:ok, %{status: status, headers: headers}} when status in 200..299 ->
        accept_media(url, headers)

      {:ok, %{status: status}} ->
        Logger.warning("RedirectResolver: unexpected status #{status} for #{sanitize(url)}")

        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A 2xx only ends the chain when it actually carries media. Providers
  # (and the CDNs in front of them) answer 200 + `text/html` for expired
  # credentials, abuse pages, and — the case that motivated this — a
  # Cloudflare-cached *empty* body. Treating those as the final URL made
  # the proxy stream zero bytes with no length, which surfaces client-side
  # as a player that spins forever and then dies with `open stream failed`.
  # Rejecting here lets the caller rotate to the next host in the failover
  # chain, or fail loudly, instead of serving a stream that cannot play.
  @non_media_types ["text/html", "text/plain", "application/json", "text/xml", "application/xml"]

  defp accept_media(url, headers) do
    content_type =
      headers
      |> Map.get("content-type", [])
      |> List.first()
      |> to_string()
      |> String.downcase()

    if Enum.any?(@non_media_types, &String.starts_with?(content_type, &1)) do
      Logger.warning(
        "RedirectResolver: non-media content-type #{inspect(content_type)} for #{sanitize(url)}"
      )

      {:error, {:not_media, content_type}}
    else
      {:ok, url}
    end
  end

  defp follow_redirect(url, headers, count, opts) do
    case List.first(Map.get(headers, "location", [])) do
      nil ->
        {:error, :missing_location}

      location ->
        next_url = absolute_location(url, location)
        stop_fn = Keyword.get(opts, :stop_fn, fn _ -> false end)

        if stop_fn.(next_url) do
          {:ok, next_url}
        else
          do_walk(next_url, count + 1, opts)
        end
    end
  end

  defp build_req_opts(opts) do
    extra = Keyword.get(opts, :req_options, [])

    [
      redirect: false,
      retry: false,
      headers: [{"user-agent", UpstreamPolicy.user_agent()}],
      decode_body: false,
      # Tight timeouts: a healthy provider responds with a 302 in
      # under 1s. Anything past 8s receive or 5s connect is almost
      # certainly a dead cluster IP — fail fast so the chain can
      # restart and roll the dice on a different IP.
      receive_timeout: 8_000,
      connect_options: [timeout: 5_000],
      into: &halt_after_first_chunk/2
    ]
    |> Keyword.merge(Application.get_env(:streamix, :stream_proxy_req_options, []))
    |> Keyword.merge(extra)
  end

  defp halt_after_first_chunk({:data, _chunk}, {request, response}) do
    {:halt, {request, response}}
  end

  defp absolute_location(url, location) do
    absolute_url =
      if String.starts_with?(location, "http") do
        location
      else
        url
        |> URI.merge(location)
        |> URI.to_string()
      end

    normalize_redirect_path(absolute_url)
  end

  defp normalize_redirect_path(url) do
    case URI.parse(url) do
      %URI{path: path} = uri when is_binary(path) ->
        %{uri | path: URI.encode(path, &valid_uri_path_character?/1)}
        |> URI.to_string()

      _ ->
        url
    end
  end

  defp valid_uri_path_character?(character) do
    URI.char_unreserved?(character) or character in @uri_path_characters
  end

  defp sanitize(url) do
    SafeLog.redact_url(url)
  end
end
