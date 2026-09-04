defmodule Streamix.Workers.EpisodeDetailsWorker do
  @moduledoc """
  Reads TMDB season payloads to fill episode metadata in bulk.

  The catalog holds 104.975 episodes and 1.605 synopses — 1,5%. Twelve had ever
  been through TMDB. The machinery to fix that already existed and was simply
  wired one episode at a time: opening an episode's page fetches its entire
  season from TMDB, uses the one episode the visitor asked for, and discards the
  other fifteen.

  This worker takes the season as the unit of work, which is what TMDB's API
  actually is. One request fills every episode in it: **3.935 requests cover
  63.340 episodes**, roughly one call per sixteen rows. That ratio is why this
  is worth doing as a sweep rather than waiting for visitors.

  Runs in two shapes:

    * **Batch mode** — args `%{"season_ids" => [...]}`, one TMDB request each.
    * **Cron mode** — args `%{}`, picking unstamped seasons whose series carries
      a `tmdb_id`, spread across batches.

  ## What it writes, and what it deliberately does not

  Only columns neither sync path claims: `plot`, `still_path`, `air_date`,
  `rating`, `duration_secs` and `tmdb_id`, and only where the stored value is
  blank. `name` and `title` are left alone even though TMDB has better ones —
  the GIndex ingest lists both in its replace set, so writing them would buy a
  clean title until the next scan and no longer.

  `seasons.tmdb_details_at` is the marker. `episodes.tmdb_enriched` cannot be
  one: an episode number the upstream carries and TMDB does not would keep the
  flag false forever and drag its whole season back every night.
  """

  use Oban.Worker,
    queue: :tmdb_details,
    max_attempts: 3,
    priority: 3

  import Ecto.Query

  alias Streamix.Iptv.{Episode, Season, Series, TmdbClient}
  alias Streamix.Repo

  require Logger

  @cron_limit 1_500
  @batch_size 20
  @batch_delay 10
  @stale_retry_after_days 30
  @stale_retry_limit 200

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"season_ids" => ids}}) when is_list(ids) do
    seasons = load_seasons(ids)

    episodes = Enum.sum(Enum.map(seasons, &enrich_season/1))

    Logger.info("[Episode Details] seasons=#{length(seasons)} episodes_filled=#{episodes}")
    :ok
  end

  def perform(%Oban.Job{args: args}) when map_size(args) == 0 do
    summary = enqueue_pending()
    Logger.info("[Episode Details] cron enqueued #{inspect(summary)}")
    :ok
  end

  @doc """
  Enqueues pending seasons and returns what was scheduled.

  ## Options

    * `:limit` — maximum seasons (default: `#{@cron_limit}`)
    * `:batch_size` — seasons per job (default: `#{@batch_size}`)
    * `:delay` — seconds between batches (default: `#{@batch_delay}`)
  """
  @spec enqueue_pending(keyword()) :: map()
  def enqueue_pending(opts \\ []) do
    limit = Keyword.get(opts, :limit, @cron_limit)
    batch_size = Keyword.get(opts, :batch_size, @batch_size)
    delay = Keyword.get(opts, :delay, @batch_delay)

    ids = Enum.uniq(pending_season_ids(limit) ++ stale_season_ids())

    %{seasons: length(ids), batches: enqueue_batches(ids, batch_size, delay)}
  end

  # --- Enrichment ---

  defp load_seasons(ids) do
    Repo.all(
      from se in Season,
        join: s in Series,
        on: s.id == se.series_id,
        where: se.id in ^ids,
        where: not is_nil(s.tmdb_id) and s.tmdb_id != "",
        select: %{
          id: se.id,
          season_number: se.season_number,
          series_tmdb_id: s.tmdb_id,
          gindex: not is_nil(s.gindex_path) and s.gindex_path != ""
        }
    )
  end

  # The stamp goes on whether or not TMDB had the season. An absent season is an
  # answer, and re-asking nightly is what the column exists to prevent. A crash
  # leaves it unstamped, so the next pass picks it up.
  defp enrich_season(season) do
    profile = if season.gindex, do: :gindex, else: :default

    filled =
      case TmdbClient.get_season(season.series_tmdb_id, season.season_number, profile: profile) do
        {:ok, payload} -> apply_episodes(season.id, payload)
        {:error, _reason} -> 0
      end

    stamp(season.id)
    filled
  end

  defp apply_episodes(season_id, payload) do
    by_number = TmdbClient.parse_season_episodes(payload)

    season_id
    |> episodes_of()
    |> Enum.count(fn episode ->
      case Map.get(by_number, episode.episode_num) do
        nil -> false
        attrs -> write_episode(episode, attrs)
      end
    end)
  end

  defp episodes_of(season_id) do
    Repo.all(
      from e in Episode,
        where: e.season_id == ^season_id,
        select: %{
          id: e.id,
          episode_num: e.episode_num,
          plot: e.plot,
          still_path: e.still_path,
          air_date: e.air_date,
          rating: e.rating,
          duration_secs: e.duration_secs,
          tmdb_id: e.tmdb_id
        }
    )
  end

  # `:name` is dropped on purpose — see the moduledoc. Everything else fills a
  # blank and never replaces a value the provider supplied.
  defp write_episode(episode, attrs) do
    updates =
      %{}
      |> fill(:plot, episode.plot, attrs[:plot])
      |> fill(:still_path, episode.still_path, attrs[:still_path])
      |> fill(:air_date, episode.air_date, attrs[:air_date])
      |> fill(:rating, episode.rating, attrs[:rating])
      |> fill(:duration_secs, episode.duration_secs, attrs[:duration_secs])
      |> fill(:tmdb_id, episode.tmdb_id, attrs[:tmdb_id])

    if updates == %{} do
      false
    else
      set =
        updates
        |> Map.put(:tmdb_enriched, true)
        |> Map.put(:updated_at, DateTime.utc_now(:second))
        |> Map.to_list()

      {count, _} = Repo.update_all(from(e in Episode, where: e.id == ^episode.id), set: set)
      count > 0
    end
  end

  defp fill(updates, _field, _current, nil), do: updates

  defp fill(updates, field, current, value) do
    if blank?(current), do: Map.put(updates, field, value), else: updates
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp stamp(season_id) do
    Repo.update_all(
      from(se in Season, where: se.id == ^season_id),
      set: [tmdb_details_at: DateTime.utc_now(:second)]
    )
  end

  # --- Selection ---

  defp pending_season_ids(limit) do
    Repo.all(
      from se in Season,
        join: s in Series,
        on: s.id == se.series_id,
        where: is_nil(se.tmdb_details_at),
        where: not is_nil(s.tmdb_id) and s.tmdb_id != "",
        order_by: [asc: se.id],
        limit: ^limit,
        select: se.id
    )
  end

  defp stale_season_ids do
    cutoff = DateTime.add(DateTime.utc_now(:second), -@stale_retry_after_days, :day)

    Repo.all(
      from se in Season,
        as: :season,
        join: s in Series,
        on: s.id == se.series_id,
        where: se.tmdb_details_at < ^cutoff,
        where: not is_nil(s.tmdb_id) and s.tmdb_id != "",
        where:
          exists(
            from e in Episode,
              where: parent_as(:season).id == e.season_id,
              where: is_nil(e.plot) or e.plot == "",
              select: 1
          ),
        order_by: [asc: se.tmdb_details_at],
        limit: ^@stale_retry_limit,
        select: se.id
    )
  end

  defp enqueue_batches([], _batch_size, _delay), do: 0

  defp enqueue_batches(ids, batch_size, delay) do
    ids
    |> Enum.chunk_every(batch_size)
    |> Enum.with_index()
    |> Enum.reduce(0, fn {chunk, index}, acc ->
      scheduled_at = DateTime.add(DateTime.utc_now(), index * delay, :second)

      case %{"season_ids" => chunk}
           |> __MODULE__.new(scheduled_at: scheduled_at)
           |> Oban.insert() do
        {:ok, _job} -> acc + 1
        {:error, _reason} -> acc
      end
    end)
  end
end
