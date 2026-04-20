defmodule Streamix.Iptv.ProviderHealth do
  @moduledoc """
  Joins the circuit-breaker view (per-provider runtime failure state)
  with the provider rows themselves so the rest of the app can answer
  "is the upstream I'm about to hit actually up?" with a single call.

  Returns stable, client-safe payloads — every field is either a
  primitive or a short atom tag, so callers can pass the result
  straight to a JSON serializer or a LiveView assign without massaging
  it.

  ## Status vocabulary

    * `:healthy`   — no circuit entry, or circuit closed with recent
                     successes. Safe to hit upstream.
    * `:degraded`  — circuit half-open: the breaker is probing upstream,
                     most requests still go through but some may fail.
    * `:unhealthy` — circuit open: upstream is being bypassed; expect
                     cached data only until recovery.
    * `:unknown`   — provider exists but the breaker hasn't tracked it
                     yet (e.g. fresh process, no request since boot).
  """

  alias Streamix.Iptv.{Provider, XtreamCircuitBreaker}
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
    |> Enum.map(&build_report(&1, cb_by_id))
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

  defp build_report(%Provider{} = provider, cb_by_id) do
    cb = Map.get(cb_by_id, provider.id)
    status = classify(provider, cb)

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
      message: human_message(status, provider, cb)
    }
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
    cond do
      not provider.is_active -> "Provedor desativado pelo administrador."
      true -> "Provedor temporariamente indisponível. Tentando reconectar."
    end
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

  defp worst_of([]), do: :unknown

  defp worst_of(reports) do
    reports
    |> Enum.max_by(fn %{status: s} -> Map.get(@status_rank, s, 0) end)
    |> Map.fetch!(:status)
  end
end
