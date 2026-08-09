defmodule Streamix.Gindex.QuotaGuard do
  @moduledoc """
  Daily request budget tracker for the GIndex upstream.

  The underlying `*.workers.dev` deployments are shared third-party
  infrastructure: Streamix cannot inspect their account-wide usage or
  reserve capacity. This module therefore applies a conservative app-local
  ceiling and lets the Transport short-circuit before a large sync monopolizes
  the upstream or enters a retry storm. Background ingestion stops at a lower
  soft ceiling, leaving the tail of the same atomic counter reserved for
  interactive playback.

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
  @default_daily_limit 8_000
  @default_playback_reserve 1_000

  # Warn at 80% of the applicable workload ceiling. Better an early alert
  # than a silent stop near either the background or hard boundary.
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

  @type workload :: :background | :playback

  @doc """
  Atomically reserves one slot in today's shared counter.

  Background requests stop before the playback reserve. Playback requests may
  consume that reserve, but never cross the hard daily limit. Denied calls
  return the current count without incrementing it.

  Returns:
    * `{:ok, :ok, count}`           — under threshold
    * `{:ok, :warning, count}`      — at/above warning %
    * `{:error, :exhausted, count}` — workload ceiling reached, deny request
    * `{:ok, :ok, 0}`               — Redis unreachable, optimistic allow
  """
  @spec consume() ::
          {:ok, :ok | :warning, non_neg_integer()}
          | {:error, :exhausted, non_neg_integer()}
  def consume, do: consume(:background)

  @spec consume(workload()) ::
          {:ok, :ok | :warning, non_neg_integer()}
          | {:error, :exhausted, non_neg_integer()}
  def consume(workload) when workload in [:background, :playback] do
    policy = policy()
    reserve(workload, limit_for(workload, policy))
  end

  defp reserve(workload, limit) do
    key = key_for_today()

    case Redix.command(:streamix_redis, [
           "EVAL",
           @consume_script,
           "1",
           key,
           Integer.to_string(limit),
           Integer.to_string(@key_ttl)
         ]) do
      {:ok, [count, 1]} when is_integer(count) ->
        classify_allowed(count, workload, limit)

      {:ok, [count, 0]} when is_integer(count) ->
        deny(count, workload, limit)

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
    policy = policy()

    %{
      count: count,
      limit: policy.daily_limit,
      remaining: max(0, policy.daily_limit - count),
      percent: percent(count, policy.daily_limit),
      background_limit: policy.background_limit,
      background_remaining: max(0, policy.background_limit - count),
      background_percent: percent(count, policy.background_limit),
      playback_reserve: policy.playback_reserve,
      warning_pct: @warning_pct
    }
  end

  @doc "Effective workload ceilings used by quota, workers and health checks."
  @spec policy() :: %{
          daily_limit: pos_integer(),
          background_limit: pos_integer(),
          playback_reserve: non_neg_integer()
        }
  def policy do
    config = Application.get_env(:streamix, __MODULE__, [])
    daily_limit = Keyword.get(config, :daily_limit, @default_daily_limit)
    playback_reserve = Keyword.get(config, :playback_reserve, @default_playback_reserve)

    if not is_integer(daily_limit) or daily_limit < 1 do
      raise ArgumentError, "GIndex daily_limit must be a positive integer"
    end

    if not is_integer(playback_reserve) or playback_reserve < 0 or
         playback_reserve >= daily_limit do
      raise ArgumentError,
            "GIndex playback_reserve must be a non-negative integer below daily_limit"
    end

    %{
      daily_limit: daily_limit,
      background_limit: daily_limit - playback_reserve,
      playback_reserve: playback_reserve
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

  defp classify_allowed(count, workload, limit) do
    percent = percent(count, limit)

    if percent >= @warning_pct do
      if rem(count, 100) == 0 do
        Logger.warning("[GIndex Quota] WARN workload=#{workload} #{count}/#{limit} (#{percent}%)")
      end

      {:ok, :warning, count}
    else
      {:ok, :ok, count}
    end
  end

  defp deny(count, workload, limit) do
    Logger.error(
      "[GIndex Quota] EXHAUSTED workload=#{workload} #{count}/#{limit} " <>
        "(#{percent(count, limit)}%) — denying request"
    )

    {:error, :exhausted, count}
  end

  defp percent(count, limit)
       when is_integer(count) and count >= 0 and is_integer(limit) and limit > 0 do
    round(count / limit * 100)
  end

  defp limit_for(:background, policy), do: policy.background_limit
  defp limit_for(:playback, policy), do: policy.daily_limit

  defp key_for_today do
    date =
      DateTime.utc_now()
      |> DateTime.to_date()
      |> Date.to_iso8601()

    @key_prefix <> date
  end
end
