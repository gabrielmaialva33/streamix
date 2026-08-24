defmodule Streamix.Workers.BackfillTmdbAssetsWorker do
  @moduledoc """
  Backfills TMDB backdrop/image assets for movies and series that were
  enriched before `Streamix.Iptv.Movies.persist_movie_assets/3` existed,
  or whose assets are incomplete (e.g. only the single primary backdrop
  from an older parse that routed gallery backdrops to the "image"
  bucket).

  Picks items where the backdrop asset count is below
  `#{inspect(3)}` — TMDB routinely ships 5-6 gallery backdrops plus the
  primary, so anything under that threshold is almost certainly a row
  written by the broken parse pipeline.

  Fetches via the catalog application boundary, which reuses the TMDB cache
  and only hits the API when needed.

  ## Usage

  Enqueue the top-N movies and top-N series by rating:

      Streamix.Workers.BackfillTmdbAssetsWorker.enqueue_featured(limit: 200)

  Process a specific batch:

      %{kind: "movies", ids: [1, 2, 3]}
      |> Streamix.Workers.BackfillTmdbAssetsWorker.new()
      |> Oban.insert()
  """

  use Oban.Worker,
    queue: :sync,
    max_attempts: 3,
    priority: 3

  import Ecto.Query

  alias Streamix.Catalog
  alias Streamix.Iptv.{Movie, MovieAsset, Series, SeriesAsset}
  alias Streamix.Repo

  require Logger

  # Rate-limited to stay well under TMDB's ~50 req/s / 20 simultaneous
  # connection ceiling. Each fetch_info may issue up to ~3 TMDB calls
  # (search + get_{movie,series} + content_ratings etc.), so at
  # concurrency=2 we peak at ~6 inflight requests per worker. Multiple
  # workers in the `sync` queue (size 3) stay under 20 concurrent.
  @default_batch_size 25
  @default_delay 10
  @default_cron_limit 500
  @max_concurrency 2
  # Below this count the gallery was almost certainly truncated — the
  # canonical response from TMDB has the primary plus 5-6 gallery shots.
  @min_backdrops 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => "movies", "ids" => ids}}) do
    movies = Repo.all(from m in Movie, where: m.id in ^ids, preload: [:assets, :credits])
    run_batch(movies, &Catalog.fetch_movie_info/1, "movies")
  end

  def perform(%Oban.Job{args: %{"kind" => "series", "ids" => ids}}) do
    series =
      Repo.all(from s in Series, where: s.id in ^ids, preload: [:assets, credits: :person])

    run_batch(series, &Catalog.fetch_series_info/1, "series")
  end

  # Cron entrypoint — no args means "go find pending items and enqueue".
  def perform(%Oban.Job{args: args}) when args == %{} do
    summary = enqueue_featured(limit: @default_cron_limit)
    Logger.info("[BackfillTmdbAssets] cron enqueued #{inspect(summary)}")
    :ok
  end

  defp run_batch(items, fetch_fn, kind) do
    total = length(items)

    {ok_count, err_count} =
      items
      |> Task.async_stream(fetch_fn,
        max_concurrency: @max_concurrency,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce({0, 0}, fn
        {:ok, {:ok, _}}, {ok, err} -> {ok + 1, err}
        {:ok, {:error, _}}, {ok, err} -> {ok, err + 1}
        {:exit, _}, {ok, err} -> {ok, err + 1}
      end)

    Logger.info("[BackfillTmdbAssets] #{kind}: #{ok_count}/#{total} ok, #{err_count} failed")
    :ok
  end

  @doc """
  Enqueues the top-rated movies and series that still have no backdrop assets.

  ## Options

    * `:limit` - maximum items per kind (default: 200)
    * `:batch_size` - ids per job (default: #{@default_batch_size})
    * `:delay` - seconds between batches (default: #{@default_delay})
  """
  def enqueue_featured(opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    delay = Keyword.get(opts, :delay, @default_delay)

    movie_ids = pending_movie_ids(limit)
    series_ids = pending_series_ids(limit)

    movie_batches = enqueue_batches("movies", movie_ids, batch_size, delay)
    series_batches = enqueue_batches("series", series_ids, batch_size, delay)

    %{
      movies: %{ids: length(movie_ids), batches: movie_batches},
      series: %{ids: length(series_ids), batches: series_batches}
    }
  end

  # Picks top-rated movies whose backdrop gallery is incomplete. We count
  # backdrops per movie and exclude anything already at/above the healthy
  # threshold; everything else gets re-enriched. Unlike the first
  # iteration, we no longer require a tmdb_id up-front — the IPTV facade
  # resolves it via TMDB search on first run when Xtream doesn't ship one.
  defp pending_movie_ids(limit) do
    movies_with_enough_backdrops =
      from a in MovieAsset,
        where: a.asset_type == "backdrop",
        group_by: a.movie_id,
        having: count(a.id) >= ^@min_backdrops,
        select: a.movie_id

    from(m in Movie,
      where: m.id not in subquery(movies_with_enough_backdrops),
      where: not is_nil(m.rating),
      order_by: [desc: m.rating, desc: m.year],
      limit: ^limit,
      select: m.id
    )
    |> Repo.all()
  end

  defp pending_series_ids(limit) do
    series_with_enough_backdrops =
      from a in SeriesAsset,
        where: a.asset_type == "backdrop",
        group_by: a.series_id,
        having: count(a.id) >= ^@min_backdrops,
        select: a.series_id

    from(s in Series,
      where: s.id not in subquery(series_with_enough_backdrops),
      where: not is_nil(s.rating),
      order_by: [desc: s.rating, desc: s.year],
      limit: ^limit,
      select: s.id
    )
    |> Repo.all()
  end

  defp enqueue_batches(_kind, [], _size, _delay), do: 0

  defp enqueue_batches(kind, ids, size, delay) do
    batches = Enum.chunk_every(ids, size)

    batches
    |> Enum.with_index()
    |> Enum.each(fn {batch_ids, index} ->
      scheduled_at = DateTime.add(DateTime.utc_now(), index * delay, :second)

      %{kind: kind, ids: batch_ids}
      |> __MODULE__.new(scheduled_at: scheduled_at)
      |> Oban.insert!()
    end)

    length(batches)
  end
end
