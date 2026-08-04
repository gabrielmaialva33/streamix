defmodule Streamix.Iptv.ProviderHealth do
  @moduledoc """
  Joins authenticated Xtream account capabilities, circuit-breaker state and
  observed control/live/VOD traffic so the rest of the app can answer "is the
  upstream I'm about to hit actually usable?" with a single call.

  Returns stable, client-safe payloads — every field is either a
  primitive or a short atom tag, so callers can pass the result
  straight to a JSON serializer or a LiveView assign without massaging
  it.

  ## Status vocabulary

    * `:healthy`   — authenticated account plus recent successful traffic.
    * `:degraded`  — circuit half-open: the breaker is probing upstream,
                     most requests still go through but some may fail.
    * `:unhealthy` — circuit open: upstream is being bypassed; expect
                     cached data only until recovery.
    * `:unknown`   — provider exists but the breaker hasn't tracked it
                     yet (e.g. fresh process, no request since boot).
  """

  alias Streamix.Iptv.{Provider, ProviderCapabilities, XtreamCircuitBreaker, XtreamClient}
  alias Streamix.Iptv.Streaming.ProviderRuntime
  alias Streamix.Repo

  import Ecto.Query

  @type status :: :healthy | :degraded | :unhealthy | :unknown

  @type provider_report :: %{
          id: integer(),
          name: String.t(),
          provider_type: String.t() | atom(),
          visibility: String.t() | atom(),
          is_active: boolean(),
          status: status(),
          circuit_state: atom() | nil,
          last_error_at: DateTime.t() | nil,
          last_success_at: DateTime.t() | nil,
          error_count: non_neg_integer(),
          dimensions: map(),
          capabilities: map() | nil,
          capacity: map(),
          message: String.t()
        }

  @doc """
  Returns one `provider_report/0` per provider. `:hidden` provider
  types (internal/system-only) are excluded from the default listing;
  pass `include_hidden: true` if you need them.
  """
  @spec list_reports(keyword()) :: [provider_report()]
  def list_reports(opts \\ []) do
    cb_by_id = circuit_states_by_id()

    Provider
    |> scope(opts)
    |> Repo.all()
    |> Enum.map(&build_report(&1, cb_by_id, opts))
  end

  @doc """
  Summary of the overall system: one of `:healthy | :degraded | :unhealthy`,
  plus a count of providers in each state. Useful for a single
  top-of-page banner decision.

  The overall status takes the worst state across all active public
  providers — a single unhealthy provider downgrades the whole system,
  so TV clients see the outage even if there's another healthy row
  hidden in the list.
  """
  @spec overall_status() :: %{status: status(), counts: %{atom() => non_neg_integer()}}
  def overall_status do
    reports = list_reports()

    counts =
      reports
      |> Enum.frequencies_by(& &1.status)
      |> Map.new()

    %{status: worst_of(reports), counts: counts}
  end

  # --- Private ---

  defp circuit_states_by_id do
    XtreamCircuitBreaker.get_all_status()
    |> Map.new(fn entry -> {entry.provider_id, entry} end)
  rescue
    # The breaker's a GenServer; in test envs or during boot it may
    # not be up yet. Treat that as "no data" rather than crashing the
    # health endpoint.
    _ -> %{}
  end

  defp scope(query, opts) do
    query =
      if Keyword.get(opts, :include_hidden, false),
        do: query,
        else: where(query, [p], p.is_active == true)

    # `visibility` is an Ecto.Enum — hardcoding the literal string list
    # requires ^ interpolation so Ecto can cast the values. Using atom
    # literals would work too but strings match how the rest of the
    # codebase filters (see catalog_controller).
    where(query, [p], p.visibility in ^["global", "public"])
  end

  defp build_report(%Provider{} = provider, cb_by_id, opts) do
    cb = Map.get(cb_by_id, provider.id)
    probe = maybe_probe(provider, opts)
    runtime = ProviderRuntime.snapshot(provider.id)
    control_status = control_status(probe, runtime)
    status = combine_statuses([classify(provider, cb), control_status])
    dimensions = put_in(runtime.dimensions, [:control, :status], control_status)

    %{
      id: provider.id,
      name: provider.name,
      provider_type: provider.provider_type,
      visibility: provider.visibility,
      is_active: provider.is_active,
      status: status,
      circuit_state: cb && cb.circuit_state,
      last_error_at: cb && to_iso_datetime(cb.last_error),
      last_success_at: cb && to_iso_datetime(cb.last_success),
      error_count: (cb && cb.error_count) || 0,
      dimensions: dimensions,
      capabilities: runtime.capabilities,
      capacity: runtime.capacity,
      message: human_message(status, provider, cb)
    }
  end

  # The probe authenticates against player_api.php. A bare endpoint returning
  # 401/403 only proves that nginx/PHP answered; it does not prove that this
  # account is active, unexpired or below its connection budget.
  @probe_timeout :timer.seconds(4)
  @probe_cache_ttl :timer.seconds(30)

  # Wraps `probe_xtream/1` with a 30-second in-memory cache. ConCache
  # is the L1 layer that's already configured in the app's supervision
  # tree, so we get per-process safety, TTL expiry, and a cheap
  # look-up without adding infra.
  defp maybe_probe(%Provider{provider_type: :xtream} = provider, opts) do
    probe =
      cond do
        Keyword.get(opts, :probe, true) == false -> nil
        probe_fun = Keyword.get(opts, :probe_fun) -> normalize_probe(probe_fun.(provider))
        true -> provider |> cached_probe() |> normalize_probe()
      end

    maybe_store_capabilities(provider.id, probe)
    probe
  end

  defp maybe_probe(_provider, _opts), do: nil

  defp cached_probe(%Provider{id: id} = provider) do
    key = {:provider_probe, id}

    ConCache.get_or_store(:streamix_l1_cache, key, fn ->
      %ConCache.Item{
        value: probe_xtream(provider),
        ttl: @probe_cache_ttl
      }
    end)
  rescue
    # If the cache isn't available for some reason (test env), fall
    # through to the uncached probe rather than returning `:unknown`.
    _ -> probe_xtream(provider)
  end

  defp probe_xtream(%Provider{} = provider) do
    case XtreamClient.get_account_info(provider.url, provider.username, provider.password,
           provider_id: provider.id,
           allow_private_network: provider.is_system,
           request_timeout: @probe_timeout,
           max_retries: 0
         ) do
      {:ok, payload} ->
        case ProviderCapabilities.from_account_info(payload) do
          {:ok, capabilities} ->
            ProviderRuntime.put_capabilities(provider.id, capabilities)
            %{status: ProviderCapabilities.status(capabilities), capabilities: capabilities}

          {:error, :invalid_account_info} ->
            ProviderRuntime.record_failure(provider.id, :control, :authentication_failed)
            %{status: :unhealthy, capabilities: nil}
        end

      {:error, _reason} ->
        # XtreamClient already recorded a sanitized control-plane failure.
        %{status: :unhealthy, capabilities: nil}
    end
  rescue
    _ -> %{status: :unknown, capabilities: nil}
  end

  defp normalize_probe(%{status: status} = probe)
       when status in ~w(healthy degraded unhealthy unknown)a,
       do: probe

  defp normalize_probe(status) when status in ~w(healthy degraded unhealthy unknown)a,
    do: %{status: status, capabilities: nil}

  defp normalize_probe(_), do: %{status: :unknown, capabilities: nil}

  defp maybe_store_capabilities(provider_id, %{capabilities: %ProviderCapabilities{} = value}),
    do: ProviderRuntime.put_capabilities(provider_id, value)

  defp maybe_store_capabilities(_provider_id, _probe), do: :ok

  defp control_status(nil, runtime), do: runtime.dimensions.control.status

  defp control_status(%{status: probe_status}, runtime) do
    combine_statuses([probe_status, runtime.dimensions.control.status])
  end

  defp classify(%Provider{is_active: false}, _cb), do: :unhealthy
  defp classify(_provider, nil), do: :unknown

  defp classify(_provider, %{circuit_state: :open}), do: :unhealthy
  defp classify(_provider, %{circuit_state: :half_open}), do: :degraded
  defp classify(_provider, %{circuit_state: :closed}), do: :healthy
  defp classify(_provider, _), do: :unknown

  # Copy is server-side so the TV and the web share the same wording.
  # Keep it provider-neutral — never leak the upstream hostname.
  defp human_message(:healthy, _, _), do: "Provedor operando normalmente."

  defp human_message(:degraded, _, _),
    do: "Provedor intermitente. Algumas mídias podem demorar mais para carregar."

  defp human_message(:unhealthy, provider, _) do
    if provider.is_active,
      do: "Provedor temporariamente indisponível. Tentando reconectar.",
      else: "Provedor desativado pelo administrador."
  end

  defp human_message(:unknown, _, _),
    do: "Estado do provedor desconhecido — ainda não houve tráfego nesta sessão."

  # Monotonic-time samples recorded by the breaker need to be folded
  # back into wall-clock time before we ship them across a JSON boundary.
  defp to_iso_datetime(nil), do: nil

  defp to_iso_datetime(mono_ms) when is_integer(mono_ms) do
    offset_ms =
      System.system_time(:millisecond) - System.monotonic_time(:millisecond)

    DateTime.from_unix!(mono_ms + offset_ms, :millisecond)
  end

  @status_rank %{healthy: 0, unknown: 1, degraded: 2, unhealthy: 3}

  defp combine_statuses(statuses) do
    known = Enum.reject(statuses, &(&1 == :unknown))

    case known do
      [] -> :unknown
      values -> Enum.max_by(values, &Map.fetch!(@status_rank, &1))
    end
  end

  defp worst_of([]), do: :unknown

  defp worst_of(reports) do
    reports
    |> Enum.max_by(fn %{status: s} -> Map.get(@status_rank, s, 0) end)
    |> Map.fetch!(:status)
  end
end
