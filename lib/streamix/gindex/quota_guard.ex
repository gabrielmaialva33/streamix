defmodule Streamix.Gindex.QuotaGuard do
  @moduledoc """
  Daily request budget tracker for the GIndex upstream.

  The Cloudflare Worker free-tier ceiling is ~10K req/day per account
  (the underlying `*.workers.dev` deployments behind `gindex.mahina.cloud`).
  Once we hit it, every subsequent request returns 503 until the next
  UTC midnight — and worse, the worker stops responding fast enough for
  the Transport to even tell us why. So instead of waiting for the cliff,
  this module pre-counts our consumption in Redis with a generous safety
  margin (`@daily_limit`) and lets the Transport short-circuit before
  burning more budget on a guaranteed failure.

  Counter shape: `gindex:quota:YYYY-MM-DD` → integer, INCR'd per request,
  EXPIRE'd 36h to survive UTC rollover. Distributed-safe if multiple
  BEAM instances ever share the same upstream (today we run one node,
  but the cost of using Redis over ETS is negligible and saves a
  migration later).

  Failure mode: any Redix exception (e.g. Redis down) opens the gate —
  better to let the sync hit the real ceiling than block on our own
  bookkeeping. The Transport already handles 503s.
  """

  require Logger

  # Stay 20% under the 10K/day CF cliff. Buys headroom for ad-hoc IEx
  # probing, the stream proxy resolving signed URLs on demand, and the
  # 2-3 retries each Transport call may issue without consuming a fresh
  # quota slot (we only consume at the public API boundary).
  @daily_limit 8_000

  # Warn at 80% of the budget. 6_400 reqs in a single sync would be
  # exceptional but not impossible — better an early alert than a
  # silent crash near the ceiling.
  @warning_pct 80

  @key_prefix "gindex:quota:"
  # 36h covers a UTC rollover even with clock drift on the BEAM host
  # vs Redis. The next-day key starts fresh anyway, so a stale 36h
  # entry costs at most one extra KB in Redis.
  @key_ttl 36 * 60 * 60

  @doc """
  Increments today's counter by 1 and classifies the result.

  Returns:
    * `{:ok, :ok, count}`           — under threshold
    * `{:ok, :warning, count}`      — at/above warning %
    * `{:error, :exhausted, count}` — over `@daily_limit`, deny request
    * `{:ok, :ok, 0}`               — Redis unreachable, optimistic allow
  """
  def consume do
    key = key_for_today()

    case Redix.pipeline(:streamix_redis, [["INCR", key], ["EXPIRE", key, @key_ttl]]) do
      {:ok, [count, _]} when is_integer(count) ->
        classify(count)

      _ ->
        {:ok, :ok, 0}
    end
  rescue
    _ -> {:ok, :ok, 0}
  end

  @doc """
  Returns today's count without incrementing.
  """
  def current_count do
    case Redix.command(:streamix_redis, ["GET", key_for_today()]) do
      {:ok, nil} -> 0
      {:ok, value} when is_binary(value) -> String.to_integer(value)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  @doc """
  Snapshot for `/admin` views or IEx inspection.
  """
  def status do
    count = current_count()

    %{
      count: count,
      limit: @daily_limit,
      remaining: max(0, @daily_limit - count),
      percent: percent(count),
      warning_pct: @warning_pct
    }
  end

  @doc """
  Manual override — useful when bumping CF Worker to the paid plan or
  testing. Resets today's counter to zero.
  """
  def reset_today do
    case Redix.command(:streamix_redis, ["DEL", key_for_today()]) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp classify(count) do
    percent = percent(count)

    cond do
      count > @daily_limit ->
        Logger.error(
          "[GIndex Quota] EXHAUSTED #{count}/#{@daily_limit} (#{percent}%) — denying request"
        )

        {:error, :exhausted, count}

      percent >= @warning_pct ->
        if rem(count, 100) == 0 do
          Logger.warning("[GIndex Quota] WARN #{count}/#{@daily_limit} (#{percent}%)")
        end

        {:ok, :warning, count}

      true ->
        {:ok, :ok, count}
    end
  end

  defp percent(count) when is_integer(count) and count >= 0 do
    round(count / @daily_limit * 100)
  end

  defp key_for_today do
    date =
      DateTime.utc_now()
      |> DateTime.to_date()
      |> Date.to_iso8601()

    @key_prefix <> date
  end
end
