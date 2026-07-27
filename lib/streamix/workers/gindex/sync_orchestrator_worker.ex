defmodule Streamix.Workers.Gindex.SyncOrchestratorWorker do
  @moduledoc """
  Fan-in worker that finalizes a GIndex sync run once every
  `ScanRootWorker` sibling sharing the same `workflow_id` has left an
  in-flight state.

  This is the open-source equivalent of an Oban Pro
  `Workflow.add_cascade(:finalize, ..., deps: [...])` — without a
  Pro license, we simulate the dependency by:

    1. tagging every `ScanRootWorker` in a dispatch with a shared
       `workflow_id` in `args`,
    2. enqueueing one of these orchestrator jobs with the same
       `workflow_id`,
    3. the orchestrator checks via `Oban.Job` query whether any
       sibling is still `available | scheduled | executing |
       retryable`, and
    4. if so, `{:snooze, 30}` — it's cheap, non-blocking, and
       participates in Oban's scheduler like any other job.

  Once every sibling has settled (`completed | cancelled |
  discarded`), the orchestrator consolidates stats (movies / series
  counts) from the `providers` row, flips `sync_status` to
  `completed`, and returns `:ok`. The operator sees one summary log
  line per run instead of a silence that never resolves.
  """

  use Oban.Worker,
    queue: :gindex_dispatch,
    max_attempts: 120,
    priority: 1,
    # One orchestrator per workflow is plenty. `keys: [:workflow_id]`
    # in open-source Oban doesn't scope the uniqueness check tightly
    # enough — an earlier attempt produced `conflict=true` against a
    # ScanRootWorker that happened to share the same workflow_id in
    # args, because the uniqueness hash collapsed across workers.
    # Scoping by `worker` keeps the check on orchestrator-vs-
    # orchestrator, and the args are already tagged with a fresh UUID
    # workflow_id per dispatch, so collisions never happen in practice.
    unique: [
      period: :timer.hours(1),
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  alias Streamix.Iptv.{Episode, Movie, Provider, Season, Series}
  alias Streamix.Repo
  alias Streamix.Workers.Gindex.BackfillTmdbWorker

  require Logger

  @scan_worker "Streamix.Workers.Gindex.ScanRootWorker"
  @in_flight_states ~w(available scheduled executing retryable)
  # 30 seconds between checks — cheap enough not to pressure the DB
  # but tight enough that the finalization isn't visibly lagged.
  @poll_interval 30

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"workflow_id" => workflow_id, "provider_id" => provider_id} = args,
        attempt: attempt
      }) do
    in_flight = in_flight_siblings(workflow_id)
    siblings = length(in_flight)
    total = Map.get(args, "total_roots", 0)

    if siblings > 0 do
      poll_interval = poll_interval(in_flight)

      Logger.info(
        "[GIndex Orchestrator] workflow=#{workflow_id} waiting " <>
          "(#{siblings}/#{total} in flight: #{format_in_flight(in_flight)}, " <>
          "attempt #{attempt}, next check in #{poll_interval}s)"
      )

      {:snooze, poll_interval}
    else
      stats = collect_stats(workflow_id, provider_id)
      finalize(provider_id, workflow_id, stats)
    end
  end

  # --- Private ---

  defp in_flight_siblings(workflow_id) do
    # Fragment match on args->>'workflow_id' — `oban_jobs.args` is
    # a jsonb column, so `->>` is indexable and the comparison is
    # cheap even on a fat jobs table.
    from(j in Oban.Job,
      where: j.worker == ^@scan_worker,
      where: j.state in ^@in_flight_states,
      where: fragment("?->>'workflow_id' = ?", j.args, ^workflow_id),
      select: %{
        state: j.state,
        kind: fragment("?->>'kind'", j.args),
        path: fragment("?->>'path'", j.args),
        scheduled_at: j.scheduled_at
      }
    )
    |> Repo.all()
  end

  defp format_in_flight(in_flight) do
    Enum.map_join(in_flight, " ", fn %{state: state, kind: kind, path: path} ->
      "#{kind}:#{path}[#{state}]"
    end)
  end

  defp poll_interval(in_flight) do
    if Enum.all?(in_flight, &(&1.state == "scheduled")) do
      now = DateTime.utc_now()

      in_flight
      |> Enum.map(& &1.scheduled_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(DateTime, fn -> nil end)
      |> case do
        nil -> @poll_interval
        scheduled_at -> max(@poll_interval, DateTime.diff(scheduled_at, now, :second) + 5)
      end
    else
      @poll_interval
    end
  end

  defp collect_stats(workflow_id, provider_id) do
    # Pull the final per-sibling stats from Oban's `meta` to surface a
    # single-line summary at the end. Siblings don't have to write
    # meta for us to succeed — we still recompute counts directly from
    # the DB at finalize time.
    roots =
      from(j in Oban.Job,
        where: j.worker == ^@scan_worker,
        where: fragment("?->>'workflow_id' = ?", j.args, ^workflow_id),
        select: {j.state, j.args, j.meta}
      )
      |> Repo.all()

    rolled_up =
      Enum.reduce(roots, %{movies: 0, series: 0, animes: 0, episodes: 0}, fn
        {_state, _args, %{"stats" => stats}}, acc when is_map(stats) ->
          %{
            movies: acc.movies + Map.get(stats, "movies_count", 0),
            series: acc.series + Map.get(stats, "series_count", 0),
            animes: acc.animes + Map.get(stats, "animes_count", 0),
            episodes: acc.episodes + Map.get(stats, "episodes_count", 0)
          }

        _, acc ->
          acc
      end)

    %{
      provider_id: provider_id,
      roots_total: length(roots),
      roots_completed: Enum.count(roots, fn {state, _, _} -> state == "completed" end),
      roots_failed:
        Enum.count(roots, fn {state, _, _} -> state in ["cancelled", "discarded"] end),
      rolled_up: rolled_up
    }
  end

  defp finalize(provider_id, workflow_id, stats) do
    final_status = if stats.roots_failed == 0, do: "completed", else: "failed"

    counts = recount_provider(provider_id)

    Logger.info(
      "[GIndex Orchestrator] workflow=#{workflow_id} finalizing: " <>
        "status=#{final_status} roots=#{stats.roots_completed}/#{stats.roots_total} " <>
        "(#{stats.roots_failed} failed) " <>
        "rolled_up=#{inspect(stats.rolled_up)} db_counts=#{inspect(counts)}"
    )

    case Repo.get(Provider, provider_id) do
      nil ->
        Logger.warning("[GIndex Orchestrator] provider #{provider_id} not found, skipping")
        :ok

      provider ->
        attrs =
          %{
            sync_status: final_status,
            vod_synced_at: DateTime.utc_now() |> DateTime.truncate(:second)
          }
          |> Map.merge(counts)

        provider
        |> Provider.sync_changeset(attrs)
        |> Repo.update()

        # Kick off TMDB enrichment as soon as the catalog is settled.
        # We trigger on partial-success runs too (status=failed but DB
        # rows present) because the fresh rows still need posters; the
        # nightly 03:30 cron is the safety net if this enqueue fails.
        # 30s schedule_in gives Postgres time to commit the provider
        # update before the enrich worker queries.
        maybe_enqueue_enrich(counts, workflow_id)

        :ok
    end
  end

  defp maybe_enqueue_enrich(%{movies_count: m, series_count: s}, workflow_id)
       when m > 0 or s > 0 do
    case %{}
         |> BackfillTmdbWorker.new(schedule_in: 30)
         |> Oban.insert() do
      {:ok, %Oban.Job{id: id, conflict?: conflict}} ->
        Logger.info(
          "[GIndex Orchestrator] workflow=#{workflow_id} enqueued enrich job=#{id} " <>
            "conflict=#{conflict}"
        )

      {:error, reason} ->
        Logger.warning(
          "[GIndex Orchestrator] workflow=#{workflow_id} failed to enqueue enrich: " <>
            inspect(reason)
        )
    end
  end

  defp maybe_enqueue_enrich(_counts, _workflow_id), do: :ok

  # Counts come from the DB rather than the rolled-up sibling stats so
  # the provider row matches reality even when meta is missing (e.g.
  # ScanRoot failed before writing meta, or a Lifeline-rescued attempt
  # produced partial output). The rolled-up numbers above are still
  # logged for visibility into per-run throughput.
  defp recount_provider(provider_id) do
    movies =
      Movie
      |> where(provider_id: ^provider_id)
      |> select(count())
      |> Repo.one()

    series =
      Series
      |> where(provider_id: ^provider_id)
      |> select(count())
      |> Repo.one()

    series_synced_at =
      case has_episodes?(provider_id) do
        true -> DateTime.utc_now() |> DateTime.truncate(:second)
        false -> nil
      end

    %{
      movies_count: movies || 0,
      series_count: series || 0,
      series_synced_at: series_synced_at
    }
  end

  # Episode belongs to Season, Season belongs to Series. There is no
  # direct `series_id` on Episode in the normalized schema, so we walk
  # Episode → Season → Series to scope by provider.
  defp has_episodes?(provider_id) do
    from(e in Episode,
      join: season in Season,
      on: e.season_id == season.id,
      join: s in Series,
      on: season.series_id == s.id,
      where: s.provider_id == ^provider_id,
      limit: 1,
      select: 1
    )
    |> Repo.one()
    |> case do
      nil -> false
      _ -> true
    end
  end
end
