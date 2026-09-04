defmodule Streamix.Workers.Gindex.BackfillTmdbWorker do
  @moduledoc """
  Resolves a `tmdb_id` for catalog rows by matching their release string.

  Named for gindex because that is where it started, and kept there because
  Oban addresses queued jobs by module name. The matcher itself was never
  gindex-specific: `release_source/1` falls back to `name` when there is no
  `gindex_path`, and the anime pipeline only engages on an anime path. The
  selection was the only thing holding it to one source.

  It now covers the whole catalog. Production had 55.497 xtream movies whose
  provider ships `plot`, `tmdb_id` and `rating` as empty strings and zeroes —
  the fields exist in the payload and are never filled — so nothing else could
  ever identify them. They had never been through a matcher at all.

  Rows with no plot are matched first. The eligible set also holds ~77k torrent
  rows that already have a plot, a rating and a poster and only lack an id;
  ordering by id alone would interleave the two and spend the nightly budget on
  rows a viewer already sees complete.

  Runs in two shapes:

    * **Batch mode** — args `%{"kind" => "movie|series", "ids" => [...]}`
      loads the listed rows, runs each through `ReleaseParser` ➝
      `TmdbMatcher`, and writes the winning `tmdb_id`, plus the poster when
      the row has no artwork of its own.

    * **Cron mode** — args `%{}`. Grabs `@cron_limit` rows per kind with
      `tmdb_searched_at IS NULL` and enqueues them in batches of
      `@batch_size`. Runs nightly; also safe to trigger manually after a
      scan finishes.

  Every row that's touched gets `tmdb_searched_at` stamped so the next
  pass skips it. If we couldn't match, `tmdb_miss_reason` is filled in
  (`"no_results"`, `"low_score"`, `"rate_limited"`, ...) so we know why.

  Adult titles are excluded from the sweep, on the curated `categories.is_adult`
  flag. TMDB does not carry them, so every one is a guaranteed miss —
  `requeue_stale_misses/0` would put all 8.047 of them back in the pool every
  week, forever — and a search that scores past the threshold anyway would
  write a real film's synopsis and poster onto one.

  Resolving the id is only half the enrichment: `Streamix.Workers.TmdbDetailsWorker`
  reads the details for whatever this worker matches.
  """

  use Oban.Worker,
    queue: :gindex_enrich,
    max_attempts: 3,
    priority: 2

  import Ecto.Query

  alias Streamix.Gindex.{AnimeMatcher, ReleaseParser, TmdbMatcher, TomatoMatcher}
  alias Streamix.Iptv.{Movie, Series, TmdbClient}
  alias Streamix.Repo

  require Logger

  @cron_limit 1_500
  @batch_size 50
  @poster_size "w500"
  # Re-queue misses older than this so TMDB additions / transient
  # failures get a second chance. Runs once per cron-mode invocation
  # (`args=%{}`), not on continuation loops.
  @stale_miss_after_days 7
  # Loop continuation: when enqueue_pending hits the full per-kind cap
  # we're almost certainly leaving pending rows behind. Schedule a
  # follow-up cycle to drain. 5 min spaces it past the batches we just
  # queued so we don't re-pick the same ids before they've been
  # processed.
  @loop_schedule_in 5 * 60
  # Pure safety belt: cap how many continuation hops a single cron run
  # can chain. 10× @cron_limit = 15k movies + 15k series, well above
  # any realistic gindex catalog. Prevents runaway scheduling if a
  # data bug ever keeps `tmdb_searched_at` from being stamped.
  @max_loop_hops 10

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => "movie", "ids" => ids}}) when is_list(ids) do
    process_batch(Movie, :movie, ids)
  end

  def perform(%Oban.Job{args: %{"kind" => "series", "ids" => ids}}) when is_list(ids) do
    process_batch(Series, :series, ids)
  end

  def perform(%Oban.Job{args: %{"continue" => true, "hop" => hop}}) do
    drain_loop(hop)
  end

  def perform(%Oban.Job{args: args}) when map_size(args) == 0 do
    requeued = requeue_stale_misses()
    enqueued = enqueue_pending()

    Logger.info("[GIndex Enrich] cron retry_requeued=#{requeued} enqueued=#{enqueued} rows")

    maybe_continue(enqueued, 1)
  end

  # --- Batch processing ---

  defp process_batch(schema, kind, ids) do
    artwork = artwork_field(kind)

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
            gindex_path: r.gindex_path,
            artwork: field(r, ^artwork)
          }
      )

    {ok, miss} =
      Enum.reduce(rows, {0, 0}, fn row, {ok, miss} ->
        case enrich_row(schema, kind, row) do
          :hit -> {ok + 1, miss}
          :miss -> {ok, miss + 1}
        end
      end)

    Logger.info("[GIndex Enrich] kind=#{kind} batch=#{length(rows)} hit=#{ok} miss=#{miss}")

    :ok
  end

  defp enrich_row(schema, kind, row) do
    # Folder name is authoritative for the release string; fall back to
    # the display title if for some reason gindex_path wasn't set.
    raw = release_source(row)
    %{title: parsed_title, year: parsed_year} = ReleaseParser.parse(raw)
    title = fallback_title(parsed_title, row)
    year = parsed_year || row.year

    # Anime path: Tomato first (romaji + PT plot), AniList second, TMDB
    # last — each source's strength on the brazilian anime naming
    # conventions. Everything else: TMDB only, since asking AniList or
    # Tomato for live-action titles burns rate budget on guaranteed
    # misses.
    if kind == :series and anime_path?(row.gindex_path) do
      run_anime_pipeline(schema, row, title, year)
    else
      run_tmdb_only(schema, kind, row, title, year)
    end
  end

  # Tomato → AniList → TMDB pipeline, first hit wins. Miss reasons are
  # joined with `|` so operators can see which source said what.
  defp run_anime_pipeline(schema, row, title, year) do
    reasons = []

    with {:tomato_miss, reasons} <- try_tomato(schema, row, title, year, reasons),
         {:anilist_miss, reasons} <- try_anilist(schema, row, title, year, reasons),
         {:tmdb_miss, reasons} <- try_tmdb(schema, :series, row, title, year, reasons) do
      update_row(schema, row.id, %{
        tmdb_searched_at: DateTime.utc_now(:second),
        tmdb_miss_reason: Enum.join(reasons, "|")
      })

      :miss
    else
      :hit -> :hit
    end
  end

  defp try_tomato(schema, row, title, year, reasons) do
    case TomatoMatcher.best_match(title, year) do
      {:ok, match} ->
        attrs = %{
          tomato_id: match.tomato_id,
          cover: match.cover_url,
          dub_available: match.dubbed,
          tmdb_searched_at: DateTime.utc_now(:second),
          tmdb_miss_reason: nil
        }

        update_row(schema, row.id, keep_artwork(attrs, row.artwork))
        :hit

      {:miss, reason} ->
        {:tomato_miss, reasons ++ ["tomato:#{format_miss_reason(reason)}"]}
    end
  end

  defp try_anilist(schema, row, title, year, reasons) do
    case AnimeMatcher.best_match(title, year) do
      {:ok, match} ->
        attrs = %{
          anilist_id: match.anilist_id,
          cover: match.cover_url,
          tmdb_searched_at: DateTime.utc_now(:second),
          tmdb_miss_reason: nil
        }

        update_row(schema, row.id, keep_artwork(attrs, row.artwork))
        :hit

      {:miss, reason} ->
        {:anilist_miss, reasons ++ ["anilist:#{format_miss_reason(reason)}"]}
    end
  end

  defp try_tmdb(schema, kind, row, title, year, reasons) do
    case TmdbMatcher.best_match(title, year, kind) do
      {:ok, match} ->
        attrs = kind |> build_hit_attrs(match) |> keep_artwork(row.artwork)
        update_row(schema, row.id, attrs)
        :hit

      {:miss, reason} ->
        {:tmdb_miss, reasons ++ ["tmdb:#{format_miss_reason(reason)}"]}
    end
  end

  defp run_tmdb_only(schema, kind, row, title, year) do
    case try_tmdb(schema, kind, row, title, year, []) do
      :hit ->
        :hit

      {:tmdb_miss, [reason]} ->
        mark_miss(schema, row.id, reason)
    end
  end

  defp mark_miss(schema, id, reason) do
    update_row(schema, id, %{
      tmdb_searched_at: DateTime.utc_now(:second),
      tmdb_miss_reason: format_miss_reason(reason)
    })

    :miss
  end

  @doc false
  def format_miss_reason(reason) when is_binary(reason), do: reason
  def format_miss_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  def format_miss_reason(reason), do: inspect(reason)

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

  defp artwork_field(:movie), do: :stream_icon
  defp artwork_field(:series), do: :cover

  defp build_hit_attrs(:movie, match) do
    %{
      tmdb_id: match.tmdb_id,
      stream_icon: TmdbClient.image_url(match.poster_path, @poster_size),
      tmdb_searched_at: DateTime.utc_now(:second),
      tmdb_miss_reason: nil
    }
  end

  defp build_hit_attrs(:series, match) do
    %{
      tmdb_id: match.tmdb_id,
      cover: TmdbClient.image_url(match.poster_path, @poster_size),
      tmdb_searched_at: DateTime.utc_now(:second),
      tmdb_miss_reason: nil
    }
  end

  # Artwork is only ever filled in, never replaced. Two reasons it can't be a
  # blind write: TMDB has rows with no poster uploaded, and — since the sweep
  # widened past gindex — 55.067 of the xtream rows it now visits already
  # carry a poster from their provider. The tmdb_id and the timestamp persist
  # either way, so a skipped poster never costs a re-query.
  @doc false
  def keep_artwork(attrs, existing) do
    incoming = attrs[:stream_icon] || attrs[:cover]

    if blank?(incoming) or not blank?(existing) do
      Map.drop(attrs, [:stream_icon, :cover])
    else
      attrs
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp update_row(schema, id, attrs) do
    from(r in schema, where: r.id == ^id)
    |> Repo.update_all(set: Map.to_list(attrs))
  end

  # --- Cron enqueue ---

  defp drain_loop(hop) when is_integer(hop) and hop > @max_loop_hops do
    Logger.warning(
      "[GIndex Enrich] continuation hop=#{hop} exceeded #{@max_loop_hops}, halting drain"
    )

    :ok
  end

  defp drain_loop(hop) do
    enqueued = enqueue_pending()
    Logger.info("[GIndex Enrich] drain hop=#{hop} enqueued=#{enqueued} rows")
    maybe_continue(enqueued, hop + 1)
  end

  defp maybe_continue(enqueued, next_hop) do
    if enqueued >= @cron_limit do
      case %{"continue" => true, "hop" => next_hop}
           |> __MODULE__.new(schedule_in: @loop_schedule_in)
           |> Oban.insert() do
        {:ok, %Oban.Job{id: id}} ->
          Logger.info(
            "[GIndex Enrich] queued continuation job=#{id} hop=#{next_hop} " <>
              "in #{@loop_schedule_in}s"
          )

        {:error, reason} ->
          Logger.warning(
            "[GIndex Enrich] failed to queue continuation hop=#{next_hop}: #{inspect(reason)}"
          )
      end
    end

    :ok
  end

  # Wipe `tmdb_searched_at` on rows that missed more than `@stale_miss_after_days`
  # ago so they re-enter the eligibility pool. TMDB ships titles late, parse
  # heuristics improve, and transient network errors get encoded as misses;
  # without retry, the system never recovers them. Bounded UPDATE keeps
  # this cheap on a large catalog.
  defp requeue_stale_misses do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@stale_miss_after_days * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)

    {movie_n, _} =
      from(m in Movie,
        where:
          not is_nil(m.tmdb_miss_reason) and
            not is_nil(m.tmdb_searched_at) and
            m.tmdb_searched_at < ^cutoff
      )
      |> Repo.update_all(set: [tmdb_searched_at: nil, tmdb_miss_reason: nil])

    {series_n, _} =
      from(s in Series,
        where:
          not is_nil(s.tmdb_miss_reason) and
            not is_nil(s.tmdb_searched_at) and
            s.tmdb_searched_at < ^cutoff
      )
      |> Repo.update_all(set: [tmdb_searched_at: nil, tmdb_miss_reason: nil])

    movie_n + series_n
  end

  defp enqueue_pending do
    movie_ids = pending_ids(Movie, @cron_limit)
    series_ids = pending_ids(Series, @cron_limit)

    enqueue_batches("movie", movie_ids) + enqueue_batches("series", series_ids)
  end

  # Rows with nothing to show come first. Ordering by id alone would interleave
  # the 55.511 xtream rows — which have no plot, no rating, no poster from
  # anywhere — with 76.913 torrent rows that already carry all three and only
  # want an id. Same nightly budget either way; this spends it where a viewer
  # can see the difference, and cuts the xtream backlog from ~9 nights to ~4.
  defp pending_ids(schema, limit) do
    starving = Repo.all(pending_query(schema, limit, :without_plot))
    remaining = limit - length(starving)

    if remaining > 0 do
      starving ++ Repo.all(pending_query(schema, remaining, :with_plot))
    else
      starving
    end
  end

  defp pending_query(schema, limit, plot_state) do
    from(r in schema,
      where: is_nil(r.tmdb_searched_at),
      # The matcher's job is to *find* an id. A row that has one is already
      # answered, and re-deciding it by fuzzy name match could only make it
      # worse.
      where: is_nil(r.tmdb_id) or r.tmdb_id == "",
      where:
        is_nil(r.catalog_item_id) or
          r.catalog_item_id not in subquery(adult_catalog_items()),
      order_by: [asc: r.id],
      limit: ^limit,
      select: r.id
    )
    |> filter_by_plot(plot_state)
  end

  defp filter_by_plot(query, :without_plot),
    do: where(query, [r], is_nil(r.plot) or r.plot == "")

  defp filter_by_plot(query, :with_plot),
    do: where(query, [r], not is_nil(r.plot) and r.plot != "")

  # `categories.is_adult` is the curated flag and it is complete: in production
  # it covers all 8.047 adult rows, and matching on the title instead would add
  # exactly one more — a `^xxx ` hit that is as likely to be the Vin Diesel
  # film as anything else. The flag alone, then, with no title heuristic.
  #
  # Join tables are addressed by name rather than by schema module: this worker
  # has no business reaching into another context's schemas, and the two
  # columns it needs are stable.
  defp adult_catalog_items do
    from ic in "item_categories",
      join: c in "categories",
      on: c.id == ic.category_id,
      where: c.is_adult,
      select: ic.catalog_item_id
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
