defmodule Streamix.Workers.Gindex.ScanRootWorker do
  @moduledoc """
  Scans a single GIndex scan root (`base_url` + `path` + `kind`) into the
  database. One of these jobs exists per root, which means a stuck or slow
  path can't starve the others — each root gets its own Oban attempt budget,
  timeout, and back-off.

  Args (all strings/integers — Oban serializes to JSON):
    * `"provider_id"` — the `Provider.id` whose drives are being ingested
    * `"base_url"`    — the GIndex base URL to hit
    * `"path"`        — the path inside the index (e.g. `"/1:/Filmes/"`)
    * `"kind"`        — `"movies" | "series" | "animes"`

  Idempotent via the default upsert logic in `Streamix.Iptv.Gindex.Sync`.
  """

  use Oban.Worker,
    queue: :gindex_scan,
    # Bumped 3 → 5. The scrapers now surface upstream 500s instead of
    # swallowing them as empty success, so a flaky Cloudflare Worker
    # shard burns one attempt instead of pinning the provider to
    # sync_status=completed with zero series. Oban's exponential
    # backoff pairs with the 30s GIndex token cooldown nicely; 5 tries
    # spans roughly the worst-case CF outage window we observed.
    max_attempts: 5,
    # Priority 1 (vs default 3) keeps ScanRoot ahead of lower-urgency
    # work when the scheduler is picking from a backlog — ensures a
    # cron-triggered sync isn't starved by other sync-queue traffic.
    priority: 1,
    # Don't re-enqueue the same root while one is still running or scheduled —
    # protects against a cron tick landing on top of a still-running dispatch.
    unique: [
      period: :timer.hours(1),
      fields: [:args],
      states: [:available, :scheduled, :executing]
    ]

  alias Streamix.Iptv.Gindex.Sync
  alias Streamix.Iptv.Provider
  alias Streamix.Repo

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  @impl Oban.Worker
  def perform(
        %Oban.Job{
          args: %{
            "provider_id" => provider_id,
            "base_url" => base_url,
            "path" => path,
            "kind" => kind
          }
        } = job
      ) do
    with %Provider{} = provider <- Repo.get(Provider, provider_id),
         {:ok, kind_atom} <- parse_kind(kind) do
      Logger.info("[GIndex ScanRoot] start provider=#{provider_id} kind=#{kind} path=#{path}")
      started_at = System.monotonic_time(:millisecond)

      case Sync.sync_kind(provider, base_url, path, kind_atom) do
        {:ok, stats} ->
          took_ms = System.monotonic_time(:millisecond) - started_at

          Logger.info(
            "[GIndex ScanRoot] done provider=#{provider_id} kind=#{kind} path=#{path} " <>
              "stats=#{inspect(stats)} took=#{took_ms}ms"
          )

          :telemetry.execute(
            [:streamix, :gindex, :scan_root, :stop],
            %{duration_ms: took_ms},
            %{provider_id: provider_id, kind: kind_atom, path: path, stats: stats}
          )

          # Persist per-root stats into Oban.Job.meta — the orchestrator
          # reads it to surface a clean roll-up at the end of the run.
          write_meta(job, %{
            "kind" => kind,
            "path" => path,
            "stats" => stringify_stats(stats),
            "took_ms" => took_ms
          })

          :ok

        {:error, reason} = err ->
          Logger.warning(
            "[GIndex ScanRoot] failed provider=#{provider_id} kind=#{kind} path=#{path} " <>
              "reason=#{inspect(reason)}"
          )

          err
      end
    else
      nil ->
        Logger.warning("[GIndex ScanRoot] provider #{provider_id} not found, discarding")
        {:cancel, :provider_not_found}

      {:error, :invalid_kind} ->
        Logger.warning("[GIndex ScanRoot] invalid kind #{inspect(kind)}, discarding")
        {:cancel, :invalid_kind}
    end
  end

  defp parse_kind("movies"), do: {:ok, :movies}
  defp parse_kind("series"), do: {:ok, :series}
  defp parse_kind("animes"), do: {:ok, :animes}
  defp parse_kind(_), do: {:error, :invalid_kind}

  # Atom-keyed maps don't survive jsonb round-trips cleanly, so flatten
  # to string keys before handing off to the orchestrator.
  defp stringify_stats(stats) when is_map(stats) do
    for {k, v} <- stats, into: %{}, do: {to_string(k), v}
  end

  defp stringify_stats(_), do: %{}

  defp write_meta(%Oban.Job{id: id, meta: existing}, payload) do
    new_meta = Map.merge(existing || %{}, payload)

    case Repo.get(Oban.Job, id) do
      nil ->
        :ok

      job ->
        job
        |> Ecto.Changeset.change(meta: new_meta)
        |> Repo.update()
        |> case do
          {:ok, _} ->
            :ok

          {:error, changeset} ->
            Logger.warning("[GIndex ScanRoot] meta write failed: #{inspect(changeset.errors)}")
            :ok
        end
    end
  end
end
