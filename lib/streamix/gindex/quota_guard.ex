defmodule Streamix.Gindex.QuotaGuard do
  @moduledoc """
  Daily request budget tracker for the GIndex upstream.

  The underlying `*.workers.dev` deployments are shared third-party
  infrastructure: Streamix cannot inspect their account-wide usage or
  reserve capacity. This module therefore applies a conservative app-local
  ceiling (`@daily_limit`) and lets the Transport short-circuit before a
  large sync monopolizes the upstream or enters a retry storm.

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

  # Production safety envelope based on observed upstream stability. Every
  # outbound attempt, including retries, consumes a slot so this counter
  # reflects the load Streamix actually contributes. This is intentionally
  # independent from Cloudflare's published account-plan allowance.
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
  @reset_buffer_seconds 5

  # Atomically reserve a slot without incrementing an already exhausted
  # counter. The old INCR-first flow turned every denied request into a
  # larger counter, which made retry storms look like real upstream usage.
  @consume_script """
  local current = tonumber(redis.call("GET", KEYS[1]) or "0")
  local limit = tonumber(ARGV[1])

  if current >= limit then
    return {current, 0}
  end

  local count = redis.call("INCR", KEYS[1])
  redis.call("EXPIRE", KEYS[1], tonumber(ARGV[2]))
  return {count, 1}
  """

  @doc """
  Atomically reserves one slot in today's counter and classifies the result.
  Once exhausted, denied calls return the current count without incrementing it.

  Returns:
    * `{:ok, :ok, count}`           — under threshold
    * `{:ok, :warning, count}`      — at/above warning %
    * `{:error, :exhausted, count}` — over `@daily_limit`, deny request
    * `{:ok, :ok, 0}`               — Redis unreachable, optimistic allow
  """
  def consume do
    key = key_for_today()

    case Redix.command(:streamix_redis, [
           "EVAL",
           @consume_script,
           "1",
           key,
           Integer.to_string(@daily_limit),
           Integer.to_string(@key_ttl)
         ]) do
      {:ok, [count, 1]} when is_integer(count) ->
        classify_allowed(count)

      {:ok, [count, 0]} when is_integer(count) ->
        deny(count)

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

  @doc """
  Seconds until the next UTC quota window, with a small clock-skew buffer.
  """
  @spec seconds_until_reset(DateTime.t()) :: pos_integer()
  def seconds_until_reset(now \\ DateTime.utc_now()) do
    next_date = now |> DateTime.to_date() |> Date.add(1)
    {:ok, next_midnight} = DateTime.new(next_date, ~T[00:00:00], "Etc/UTC")

    max(1, DateTime.diff(next_midnight, now, :second) + @reset_buffer_seconds)
  end

  defp classify_allowed(count) do
    percent = percent(count)

    if percent >= @warning_pct do
      if rem(count, 100) == 0 do
        Logger.warning("[GIndex Quota] WARN #{count}/#{@daily_limit} (#{percent}%)")
      end

      {:ok, :warning, count}
    else
      {:ok, :ok, count}
    end
  end

  defp deny(count) do
    Logger.error(
      "[GIndex Quota] EXHAUSTED #{count}/#{@daily_limit} (#{percent(count)}%) — denying request"
    )

    {:error, :exhausted, count}
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
