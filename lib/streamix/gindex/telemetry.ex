defmodule Streamix.Gindex.Telemetry do
  @moduledoc """
  Aggregated telemetry counters for the GIndex ingestion pipeline.

  The CF Worker free-tier ceiling (~10K req/day, account-wide) is the
  binding constraint of the whole sync, so visibility into how that
  budget is being spent is essential. This module attaches handlers to
  the existing telemetry events and surfaces:

    * total requests since boot (rough quota counter)
    * skipped 500/TypeError responses (deterministic worker.js bug)
    * 429 / 503 rate-limit hits
    * fatal transport errors
    * scan-root completions per kind

  Counters live in an ETS counter table — cheap to bump from any
  Transport caller, cheap to read for `summary/0` / `/admin` views.
  No GenServer; the table lives for the life of the BEAM node.

  Heartbeat log lines fire every `@heartbeat_every` requests so an
  operator tailing logs sees a running budget snapshot without
  needing IEx access.
  """

  require Logger

  alias Streamix.Gindex.QuotaGuard

  @table :gindex_telemetry
  @heartbeat_every 100

  @counters [
    :requests,
    :req_ok,
    :req_500_skipped,
    :req_429,
    :req_other_error,
    :req_quota_denied,
    :scan_root_movies,
    :scan_root_series,
    :scan_root_animes,
    :scan_root_failed
  ]

  @doc """
  Initializes the ETS counter table and attaches the telemetry handlers.

  Called from `Streamix.Application.start/2`.
  """
  def setup do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

      for counter <- @counters, do: :ets.insert(@table, {counter, 0})
    end

    :telemetry.attach_many(
      "streamix-gindex-telemetry",
      [
        [:streamix, :gindex, :request, :stop],
        [:streamix, :gindex, :scan_root, :stop]
      ],
      &__MODULE__.handle_event/4,
      nil
    )

    :ok
  end

  @doc """
  Returns the current counter snapshot. Useful from IEx during a sync
  or from an admin LiveView.
  """
  def summary do
    if :ets.whereis(@table) == :undefined do
      %{}
    else
      Map.new(@counters, fn counter ->
        [{^counter, value}] = :ets.lookup(@table, counter)
        {counter, value}
      end)
    end
  end

  @doc false
  # Quota-denied requests don't burn upstream budget, so we don't bump
  # `:requests` (the rough quota counter) — just track them separately
  # to flag how often the guard is firing.
  def record_request(:quota_exhausted), do: safe_update_counter(:req_quota_denied, 1)
  def record_request(:ok), do: bump_pair(:requests, :req_ok)
  def record_request(:typeerror_skip), do: bump_pair(:requests, :req_500_skipped)
  def record_request(:rate_limited), do: bump_pair(:requests, :req_429)
  def record_request(_other), do: bump_pair(:requests, :req_other_error)

  @doc false
  def handle_event([:streamix, :gindex, :request, :stop], _measurements, %{outcome: outcome}, _) do
    record_request(outcome)
    maybe_heartbeat()
  end

  def handle_event([:streamix, :gindex, :scan_root, :stop], _m, %{kind: kind, stats: _}, _) do
    counter =
      case kind do
        :movies -> :scan_root_movies
        :series -> :scan_root_series
        :animes -> :scan_root_animes
        _ -> :scan_root_failed
      end

    safe_update_counter(counter, 1)
    :ok
  end

  def handle_event(_event, _m, _meta, _), do: :ok

  defp bump_pair(a, b) do
    safe_update_counter(a, 1)
    safe_update_counter(b, 1)
  end

  defp safe_update_counter(counter, delta) do
    if :ets.whereis(@table) != :undefined do
      :ets.update_counter(@table, counter, delta, {counter, 0})
    end

    :ok
  end

  defp maybe_heartbeat do
    case :ets.lookup(@table, :requests) do
      [{:requests, count}] when rem(count, @heartbeat_every) == 0 and count > 0 ->
        snapshot = summary()
        quota = QuotaGuard.status()

        Logger.info(
          "[GIndex Telemetry] heartbeat: " <>
            "requests=#{snapshot.requests} ok=#{snapshot.req_ok} " <>
            "500_skipped=#{snapshot.req_500_skipped} 429=#{snapshot.req_429} " <>
            "other_error=#{snapshot.req_other_error} " <>
            "quota_denied=#{snapshot.req_quota_denied} " <>
            "quota=#{quota.count}/#{quota.limit}(#{quota.percent}%) " <>
            "scan_root[m=#{snapshot.scan_root_movies} s=#{snapshot.scan_root_series} " <>
            "a=#{snapshot.scan_root_animes} fail=#{snapshot.scan_root_failed}]"
        )

      _ ->
        :ok
    end
  end
end
