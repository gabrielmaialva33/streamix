defmodule Streamix.Gindex.Pacer do
  @moduledoc """
  Token-bucket-ish pacing for outbound calls made by the GIndex ingestion
  pipeline.

  Backed by `Streamix.RateLimit` (Hammer). Each named bucket has a
  requests-per-second budget; callers invoke `acquire/1` right before the
  network call and block (with jitter) until a token is available. This lets
  the Oban workers run with real parallelism while still guaranteeing the
  global RPS ceiling the upstream (Google Drive, TMDB) is willing to accept.

  Buckets:
    * `:gdrive`        - Google Drive Index (Cloudflare Worker + Google Drive API).
                         Google's per-SA quota is ~10 q/s; we default to 5 q/s to
                         stay well under and leave headroom for interactive use.
    * `:tmdb_gindex`   - TMDB via the GIndex-dedicated token; default 10 q/s.

  Rates are overridable in runtime via
  `config :streamix, Streamix.Gindex.Pacer, gdrive: 5, tmdb_gindex: 10`.
  """

  require Logger

  @type bucket :: :gdrive | :tmdb_gindex | :anilist | :tomato

  # 1s window for all pacing decisions. Small enough that bursts get smoothed
  # in the same second they arrive without feeling laggy.
  @window_ms 1_000

  # How long to wait at most for a token before giving up. 60s is generous for
  # background jobs but keeps a stuck bucket from pinning a worker forever.
  @max_wait_ms 60_000

  # Jittered resleep when Hammer denies. Denial returns ms-until-window-reset,
  # we add ±150ms jitter so 4 concurrent workers don't all wake at once.
  @jitter_ms 150

  @doc """
  Blocks until a token is available for `bucket`, then returns `:ok`.

  Returns `{:error, :timeout}` if `@max_wait_ms` elapses without acquiring.
  """
  @spec acquire(bucket()) :: :ok | {:error, :timeout}
  def acquire(bucket), do: acquire(bucket, @max_wait_ms)

  @spec acquire(bucket(), non_neg_integer()) :: :ok | {:error, :timeout}
  def acquire(bucket, max_wait_ms) when is_atom(bucket) and is_integer(max_wait_ms) do
    do_acquire(bucket, System.monotonic_time(:millisecond), max_wait_ms)
  end

  defp do_acquire(bucket, started_at, max_wait_ms) do
    case Streamix.RateLimit.hit(key(bucket), @window_ms, limit_for(bucket)) do
      {:allow, _count} ->
        :ok

      {:deny, ms_until_next_window} ->
        elapsed = System.monotonic_time(:millisecond) - started_at

        if elapsed + ms_until_next_window > max_wait_ms do
          Logger.warning(
            "[GIndex Pacer] timed out acquiring #{bucket} after #{elapsed}ms " <>
              "(budget=#{limit_for(bucket)}/s)"
          )

          {:error, :timeout}
        else
          Process.sleep(ms_until_next_window + :rand.uniform(@jitter_ms))
          do_acquire(bucket, started_at, max_wait_ms)
        end
    end
  end

  @doc """
  Returns the configured requests-per-second limit for `bucket`.

  Useful for tests and for logging the effective budget.
  """
  @spec limit_for(bucket()) :: pos_integer()
  def limit_for(bucket) do
    Application.get_env(:streamix, __MODULE__, [])
    |> Keyword.get(bucket, default_limit(bucket))
  end

  # Cloudflare Workers free-tier daily ceiling for the upstream
  # `*.workers.dev` instances we depend on is ~10 000 req/day per
  # account, shared across every client of that worker. At 5 q/s we
  # were burning that bucket in roughly half an hour and then spending
  # the rest of the run absorbing 503 storms. 1 q/s caps us at 60 req/min
  # (~3 600/h, ~14h before hitting the daily ceiling), which gives the
  # token bucket time to refill and matches what we observed as the
  # break-even rate during last night's sync attempts.
  defp default_limit(:gdrive), do: 1
  defp default_limit(:tmdb_gindex), do: 10
  # AniList's published ceiling is 90 req/min ≈ 1.5 rps. Staying at 1
  # gives headroom for our own retries plus anyone else on the same
  # outbound IP, and keeps the backfill well under the daily quota.
  defp default_limit(:anilist), do: 1
  # TomatoAnimes has no documented limit; 2 rps is well below what the
  # official mobile app produces during normal use and still lets us
  # walk through ~1k animes in under 10 minutes.
  defp default_limit(:tomato), do: 2
  defp default_limit(_), do: 5

  defp key(bucket), do: "gindex_pacer:" <> Atom.to_string(bucket)
end
