defmodule Streamix.Workers.Gindex.BackfillTmdbWorker do
  @moduledoc """
  Finds posters for gindex catalog rows by asking TMDB.

  Runs in two shapes:

    * **Batch mode** — args `%{"kind" => "movie|series", "ids" => [...]}`
      loads the listed rows, runs each through `ReleaseParser` ➝
      `TmdbMatcher`, and writes the winning `poster_path` into
      `stream_icon`/`cover`, plus `tmdb_id` when we didn't have one.

    * **Cron mode** — args `%{}`. Grabs `@cron_limit` rows per kind that
      have `gindex_path IS NOT NULL AND tmdb_searched_at IS NULL` and
      enqueues them in batches of `@batch_size`. Runs nightly; also
      safe to trigger manually after a scan finishes.

  Every row that's touched gets `tmdb_searched_at` stamped so the next
  pass skips it. If we couldn't match, `tmdb_miss_reason` is filled in
  (`"no_results"`, `"low_score"`, `"rate_limited"`, ...) so we know why.
  """

  use Oban.Worker,
    queue: :gindex_enrich,
    max_attempts: 3,
    priority: 2

  import Ecto.Query

  alias Streamix.Iptv.Gindex.{AnimeMatcher, ReleaseParser, TmdbMatcher}
  alias Streamix.Iptv.{Movie, Series, TmdbClient}
  alias Streamix.Repo

  require Logger

  @cron_limit 1_500
  @batch_size 50
  @poster_size "w500"

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => "movie", "ids" => ids}}) when is_list(ids) do
    process_batch(Movie, :movie, ids)
  end

  def perform(%Oban.Job{args: %{"kind" => "series", "ids" => ids}}) when is_list(ids) do
    process_batch(Series, :series, ids)
  end

  def perform(%Oban.Job{args: args}) when map_size(args) == 0 do
    enqueued = enqueue_pending()
    Logger.info("[GIndex Enrich] cron enqueued #{enqueued} rows")
    :ok
  end

  # --- Batch processing ---

  defp process_batch(schema, kind, ids) do
    rows =
      Repo.all(
        from r in schema,
          where: r.id in ^ids,
          select: %{
            id: r.id,
            name: r.name,
            title: r.title,
            year: r.year,
            tmdb_id: r.tmdb_id,
            gindex_path: r.gindex_path
          }
      )

    {ok, miss} =
      Enum.reduce(rows, {0, 0}, fn row, {ok, miss} ->
        case enrich_row(schema, kind, row) do
          :hit -> {ok + 1, miss}
          :miss -> {ok, miss + 1}
        end
      end)

    Logger.info(
      "[GIndex Enrich] kind=#{kind} batch=#{length(rows)} hit=#{ok} miss=#{miss}"
    )

    :ok
  end

  defp enrich_row(schema, kind, row) do
    # Folder name is authoritative for the release string; fall back to
    # the display title if for some reason gindex_path wasn't set.
    raw = release_source(row)
    %{title: parsed_title, year: parsed_year} = ReleaseParser.parse(raw)
    title = fallback_title(parsed_title, row)
    year = parsed_year || row.year

    case TmdbMatcher.best_match(title, year, kind) do
      {:ok, match} ->
        attrs = build_hit_attrs(kind, match)
        update_row(schema, row.id, attrs)
        :hit

      {:miss, _reason} = miss ->
        maybe_anilist_fallback(schema, kind, row, title, year, miss)
    end
  end

  # Anime folders live under the series table (`gindex_path` starts with
  # something like `/0:/Animes/`). When TMDB can't match one, give
  # AniList a shot before writing off the row — its catalog covers the
  # romaji/fansub long-tail that TMDB plain misses.
  defp maybe_anilist_fallback(schema, :series, row, title, year, {:miss, tmdb_reason}) do
    if anime_path?(row.gindex_path) do
      case AnimeMatcher.best_match(title, year) do
        {:ok, match} ->
          attrs = %{
            anilist_id: match.anilist_id,
            cover: match.cover_url,
            tmdb_searched_at: DateTime.utc_now() |> DateTime.truncate(:second),
            tmdb_miss_reason: nil
          }

          attrs = if is_nil(match.cover_url), do: Map.delete(attrs, :cover), else: attrs

          update_row(schema, row.id, attrs)
          :hit

        {:miss, anilist_reason} ->
          update_row(schema, row.id, %{
            tmdb_searched_at: DateTime.utc_now() |> DateTime.truncate(:second),
            tmdb_miss_reason: "tmdb:#{tmdb_reason}|anilist:#{anilist_reason}"
          })

          :miss
      end
    else
      mark_miss(schema, row.id, tmdb_reason)
    end
  end

  defp maybe_anilist_fallback(schema, _kind, row, _title, _year, {:miss, reason}) do
    mark_miss(schema, row.id, reason)
  end

  defp mark_miss(schema, id, reason) do
    update_row(schema, id, %{
      tmdb_searched_at: DateTime.utc_now() |> DateTime.truncate(:second),
      tmdb_miss_reason: to_string(reason)
    })

    :miss
  end

  defp anime_path?(path) when is_binary(path) do
    String.contains?(String.downcase(path), "anime")
  end

  defp anime_path?(_), do: false

  defp release_source(row) do
    cond do
      is_binary(row.gindex_path) and row.gindex_path != "" ->
        row.gindex_path |> Path.basename() |> String.trim()

      is_binary(row.name) and row.name != "" ->
        row.name

      is_binary(row.title) and row.title != "" ->
        row.title

      true ->
        ""
    end
  end

  defp fallback_title("", row), do: row.title || row.name || ""
  defp fallback_title(title, _row), do: title

  defp build_hit_attrs(:movie, match) do
    %{
      tmdb_id: match.tmdb_id,
      stream_icon: TmdbClient.image_url(match.poster_path, @poster_size),
      tmdb_searched_at: DateTime.utc_now() |> DateTime.truncate(:second),
      tmdb_miss_reason: nil
    }
    |> drop_nil_poster()
  end

  defp build_hit_attrs(:series, match) do
    %{
      tmdb_id: match.tmdb_id,
      cover: TmdbClient.image_url(match.poster_path, @poster_size),
      tmdb_searched_at: DateTime.utc_now() |> DateTime.truncate(:second),
      tmdb_miss_reason: nil
    }
    |> drop_nil_poster()
  end

  # Never overwrite a good poster with `nil` (happens when TMDB has the
  # row but no poster asset uploaded yet). The tmdb_id + timestamp still
  # persist so we don't re-query.
  defp drop_nil_poster(attrs) do
    case attrs[:stream_icon] || attrs[:cover] do
      nil -> Map.drop(attrs, [:stream_icon, :cover])
      _ -> attrs
    end
  end

  defp update_row(schema, id, attrs) do
    from(r in schema, where: r.id == ^id)
    |> Repo.update_all(set: Map.to_list(attrs))
  end

  # --- Cron enqueue ---

  defp enqueue_pending do
    movie_ids = pending_ids(Movie, @cron_limit)
    series_ids = pending_ids(Series, @cron_limit)

    enqueue_batches("movie", movie_ids) + enqueue_batches("series", series_ids)
  end

  defp pending_ids(schema, limit) do
    Repo.all(
      from r in schema,
        where: not is_nil(r.gindex_path) and is_nil(r.tmdb_searched_at),
        order_by: [asc: r.id],
        limit: ^limit,
        select: r.id
    )
  end

  defp enqueue_batches(_kind, []), do: 0

  defp enqueue_batches(kind, ids) do
    ids
    |> Enum.chunk_every(@batch_size)
    |> Enum.with_index()
    |> Enum.reduce(0, fn {batch, idx}, acc ->
      %{"kind" => kind, "ids" => batch}
      |> __MODULE__.new(schedule_in: idx * 5)
      |> Oban.insert()

      acc + length(batch)
    end)
  end
end
