defmodule Streamix.Iptv.Streaming.ProviderEndpoints do
  @moduledoc """
  Ranks a multi-domain Xtream provider's base URLs (`Provider.url_chain/1`)
  by observed health and latency, so every upstream path — sync, health
  probe, EPG, metadata and stream URLs — prefers a live, fast domain
  instead of paying a dead domain's DNS/connect timeouts first.

  The ranking lives in the L1 ConCache (`{:provider_endpoints, id}`) and is
  refreshed in the background by `Streamix.Iptv.ProviderHealthMonitor`;
  `report/3` updates it inline whenever a request succeeds or fails over.
  """

  alias Streamix.Iptv.{Provider, XtreamClient}

  require Logger

  @cache :streamix_l1_cache
  @rank_ttl :timer.minutes(30)
  @stale_ms :timer.minutes(5)
  @probe_timeout 4_000

  @doc """
  Returns `Provider.url_chain/1` reordered by the cached ranking.

  A cached ranking whose base set differs from the current `url_chain`
  (the operator edited URLs) is ignored. Plain provider-shaped maps
  without a struct get their `url`/`urls` order back unranked.
  """
  @spec chain(Provider.t() | map()) :: [String.t()]
  def chain(provider) do
    urls = url_chain(provider)

    case provider_id(provider) && read_ranking(provider_id(provider)) do
      {ranked, _ranked_at} ->
        if Enum.sort(ranked) == Enum.sort(urls), do: ranked, else: urls

      nil ->
        urls
    end
  end

  @doc "The currently preferred base URL for the provider."
  @spec base_url(Provider.t() | map()) :: String.t() | nil
  def base_url(provider) do
    case chain(provider) do
      [base | _] -> base
      [] -> Map.get(provider, :url)
    end
  end

  @doc """
  Records an outcome for one base URL: `:ok` promotes it to the front,
  `:down` demotes it to the end.
  """
  @spec report(Provider.t() | map(), String.t(), :ok | :down) :: :ok
  def report(provider, base, outcome)
      when outcome in [:ok, :down] do
    if provider_id(provider) && base in url_chain(provider) do
      current = chain(provider)

      ranked =
        case outcome do
          :ok -> [base | List.delete(current, base)]
          :down -> List.delete(current, base) ++ [base]
        end

      # Only `refresh/2` ages the ranking: traffic reports reorder it but
      # keep the existing timestamp (or none), so steady traffic never
      # defers the periodic re-probe.
      if ranked != current do
        write_report(provider_id(provider), base, current, ranked)
      end
    end

    :ok
  end

  defp write_report(provider_id, base, current, ranked) do
    if hd(ranked) != hd(current) do
      Logger.warning("Provider endpoint switched",
        provider_id: provider_id,
        endpoint_host: host(base)
      )
    end

    ranked_at =
      case read_ranking(provider_id) do
        {_previous, ranked_at} -> ranked_at
        nil -> nil
      end

    put_ranking(provider_id, {ranked, ranked_at})
  end

  @doc """
  Probes every base URL in parallel with a cheap authenticated
  `get_account_info` call and stores a ranking: successes by ascending
  latency, then failures (in `url_chain` order). `opts[:probe]` can inject
  a `base -> {:ok, term} | {:error, term}` function for tests.
  """
  @spec refresh(Provider.t(), keyword()) :: :ok
  def refresh(%Provider{} = provider, opts \\ []) do
    probe = Keyword.get(opts, :probe) || default_probe(provider)
    bases = Provider.url_chain(provider)

    ok =
      bases
      |> Task.async_stream(
        fn base ->
          started_at = System.monotonic_time(:millisecond)
          result = probe.(base)
          {base, result, System.monotonic_time(:millisecond) - started_at}
        end,
        max_concurrency: length(bases),
        timeout: @probe_timeout + 1_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce([], fn
        {:ok, {base, {:ok, _}, latency_ms}}, ok -> [{base, latency_ms} | ok]
        _error_or_timeout, ok -> ok
      end)

    ok_bases = MapSet.new(ok, &elem(&1, 0))

    # Successes by ascending latency; everything else (errors, probe
    # timeouts) keeps its `url_chain` position at the end of the chain.
    ranked =
      Enum.map(Enum.sort_by(ok, &elem(&1, 1)), &elem(&1, 0)) ++
        Enum.reject(bases, &MapSet.member?(ok_bases, &1))

    put_ranking(provider.id, {ranked, now_ms()})
    :ok
  end

  @doc "True when there is no ranking or the cached one is older than five minutes."
  @spec refresh_due?(Provider.t() | map()) :: boolean()
  def refresh_due?(provider) do
    case provider_id(provider) && read_ranking(provider_id(provider)) do
      {_ranked, ranked_at} when is_integer(ranked_at) -> now_ms() - ranked_at > @stale_ms
      _ -> true
    end
  end

  defp url_chain(%Provider{} = provider), do: Provider.url_chain(provider)

  defp url_chain(%{url: url} = provider) do
    [url | List.wrap(Map.get(provider, :urls))]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
  end

  defp provider_id(%{id: id}), do: id
  defp provider_id(_), do: nil

  defp default_probe(%Provider{} = provider) do
    fn base ->
      XtreamClient.get_account_info(base, provider.username, provider.password,
        provider: provider,
        provider_id: provider.id,
        allow_private_network: provider.is_system,
        request_timeout: @probe_timeout,
        max_retries: 0,
        endpoint_failover: false,
        track: false
      )
    end
  end

  defp read_ranking(provider_id) do
    ConCache.get(@cache, {:provider_endpoints, provider_id})
  rescue
    _ -> nil
  end

  defp put_ranking(provider_id, ranking) do
    ConCache.put(@cache, {:provider_endpoints, provider_id}, %ConCache.Item{
      value: ranking,
      ttl: @rank_ttl
    })

    :ok
  rescue
    _ -> :ok
  end

  defp host(base) do
    case URI.parse(base) do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
