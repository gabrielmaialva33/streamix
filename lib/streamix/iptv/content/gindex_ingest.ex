defmodule Streamix.Iptv.Content.GindexIngest do
  @moduledoc false

  import Ecto.Query, warn: false

  require Logger

  alias Streamix.Iptv.{CatalogItem, CatalogItemRedirect, Episode, Movie, Season, Series}
  alias Streamix.Iptv.Sync.Helpers
  alias Streamix.Repo
  alias Streamix.WatchParty

  @movie_fields ~w(stream_id name title year container_extension gindex_path)a
  @series_fields ~w(series_id name title year gindex_path)a
  @season_fields ~w(season_number name episode_count)a
  @episode_fields ~w(episode_id episode_num title name container_extension gindex_path)a

  @movie_replace_fields ~w(name title year container_extension gindex_path updated_at)a
  @episode_replace_fields ~w(episode_id title name container_extension gindex_path updated_at)a
  @episode_renumber_fields ~w(episode_num title name container_extension gindex_path updated_at)a

  @spec upsert_movies(pos_integer(), [map()], DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def upsert_movies(provider_id, movies, %DateTime{} = now)
      when is_integer(provider_id) and provider_id > 0 and is_list(movies) do
    Repo.transact(fn -> {:ok, do_upsert_movies(provider_id, movies, now)} end)
  end

  @spec upsert_series(pos_integer(), map(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def upsert_series(provider_id, content, %DateTime{} = now)
      when is_integer(provider_id) and provider_id > 0 and is_map(content) do
    Repo.transact(fn ->
      series = upsert_series_record(provider_id, Map.fetch!(content, :series))
      episode_count = sync_seasons(series, Map.fetch!(content, :seasons), provider_id, now)
      {:ok, episode_count}
    end)
  end

  defp do_upsert_movies(_provider_id, [], _now), do: 0

  defp do_upsert_movies(provider_id, movies, now) do
    movies = Enum.uniq_by(movies, &Map.fetch!(&1, :stream_id))
    stream_ids = Enum.map(movies, &Map.fetch!(&1, :stream_id))
    existing_catalog_items = existing_movie_catalog_items(provider_id, stream_ids)
    new_stream_ids = Enum.reject(stream_ids, &Map.has_key?(existing_catalog_items, &1))

    new_catalog_item_ids =
      Helpers.pre_create_catalog_items(length(new_stream_ids), "movie", provider_id, now)

    catalog_items =
      existing_catalog_items
      |> Map.merge(Map.new(Enum.zip(new_stream_ids, new_catalog_item_ids)))

    entries =
      Enum.map(movies, fn movie ->
        stream_id = Map.fetch!(movie, :stream_id)

        movie
        |> Map.take(@movie_fields)
        |> Map.merge(%{
          provider_id: provider_id,
          catalog_item_id: Map.fetch!(catalog_items, stream_id),
          inserted_at: now,
          updated_at: now
        })
      end)

    {count, _rows} =
      Repo.insert_all(Movie, entries,
        on_conflict: {:replace, @movie_replace_fields},
        conflict_target: [:provider_id, :stream_id]
      )

    count
  end

  defp existing_movie_catalog_items(_provider_id, []), do: %{}

  defp existing_movie_catalog_items(provider_id, stream_ids) do
    Movie
    |> where(provider_id: ^provider_id)
    |> where([movie], movie.stream_id in ^stream_ids)
    |> select([movie], {movie.stream_id, movie.catalog_item_id})
    |> Repo.all()
    |> Map.new()
  end

  defp upsert_series_record(provider_id, attrs) do
    attrs = attrs |> Map.take(@series_fields) |> Map.put(:provider_id, provider_id)
    series_id = Map.fetch!(attrs, :series_id)

    case Repo.one(
           from(series in Series,
             where: series.provider_id == ^provider_id and series.series_id == ^series_id
           )
         ) do
      nil ->
        catalog_item =
          %CatalogItem{}
          |> CatalogItem.changeset(%{content_type: "series", provider_id: provider_id})
          |> Repo.insert!()

        %Series{}
        |> Series.changeset(Map.put(attrs, :catalog_item_id, catalog_item.id))
        |> Repo.insert!()

      series ->
        series
        |> Series.changeset(attrs)
        |> Repo.update!()
    end
  end

  # Every season row is upserted, and every season's listing deduped, before
  # any episode is written, because a file can change season between scans and
  # only a view of the whole series can see that. Reconciling first lets each
  # per-season upsert below stay exactly as narrow as it was.
  #
  # Deduping up front matters for the same reason: targets must be computed
  # from the entries that will actually be upserted, or a row could be moved
  # into a season whose upsert then drops its file and never unparks it.
  defp sync_seasons(series, seasons, provider_id, now) do
    scraped =
      Enum.map(seasons, fn season_content ->
        season = upsert_season(series.id, Map.fetch!(season_content, :season))
        {season, dedupe_episodes(Map.fetch!(season_content, :episodes), season.id)}
      end)

    reconcile_seasons(series, scraped)

    Enum.reduce(scraped, 0, fn {season, episodes}, episode_count ->
      episode_count + upsert_episodes(season.id, episodes, provider_id, now)
    end)
  end

  # A file whose season changed between scans used to get a second row in its
  # new season, because `upsert_episodes/4` only ever sees the season it is
  # writing. 209f6a7a taught the parser to read the season out of `SxxEyy`, and
  # from the next scan on production held pairs like
  #
  #     season 1  ep 7  Vida-S02E07 - Episódio 7.mkv  created 2026-09-20
  #     season 2  ep 7  Vida-S02E07 - Episódio 7.mkv  created 2026-10-12
  #
  # The new row starts with no history while the user's progress stays on the
  # old one, which the UI keeps showing as a duplicate. Should the old row ever
  # be deleted as a stale blocker, its catalog item is orphaned and the 02:00
  # cleanup cascades the history away.
  #
  # So, for every file listed in exactly one season of this scrape:
  #
  #   * a row of it in another season, with none in the listed one, is moved
  #     there and parked at `- id`. It keeps its catalog item, so the history
  #     follows the file, and the upsert of that season then finds it by
  #     episode_id and unparks it like any other renumbered file.
  #   * if the listed season already holds a row of it, the rows elsewhere are
  #     ghosts and are deleted. History and favorites are sealed per user, so
  #     the server cannot tell whether anyone's hang off a ghost; each deleted
  #     ghost leaves a `CatalogItemRedirect` to the row that stays, and the
  #     owner's next read moves the entry there. A ghost a watch-party room
  #     still points at is kept and logged for a human to decide.
  #
  # A file listed in more than one season of the same scrape has no single
  # right season, and neither has a row whose file is gone from the listing.
  # Both are left exactly as they were.
  defp reconcile_seasons(series, scraped) do
    targets = single_season_targets(scraped)

    misplaced =
      series.id
      |> series_episode_rows(Map.keys(targets))
      |> Enum.group_by(& &1.episode_id)
      |> Enum.flat_map(fn {episode_id, rows} ->
        target = Map.fetch!(targets, episode_id)
        {in_target, elsewhere} = Enum.split_with(rows, &(&1.season_id == target.id))
        if elsewhere == [], do: [], else: [{target, in_target, elsewhere}]
      end)

    if misplaced != [] do
      with_rooms =
        misplaced
        |> Enum.flat_map(fn {_target, _in_target, elsewhere} -> elsewhere end)
        |> Enum.map(& &1.catalog_item_id)
        |> WatchParty.catalog_item_ids_with_rooms()
        |> MapSet.new()

      {moves, ghosts} = plan_reconciliation(misplaced, with_rooms)

      move_rows(series, moves)
      drop_ghosts(series, ghosts, with_rooms)
    end

    :ok
  end

  defp single_season_targets(scraped) do
    scraped
    |> Enum.flat_map(fn {season, episodes} ->
      Enum.map(episodes, &{Map.fetch!(&1, :episode_id), season})
    end)
    |> Enum.group_by(fn {episode_id, _season} -> episode_id end, fn {_id, season} -> season end)
    |> Enum.flat_map(fn {episode_id, seasons} ->
      case Enum.uniq_by(seasons, & &1.id) do
        [season] -> [{episode_id, %{id: season.id, season_number: season.season_number}}]
        _several -> []
      end
    end)
    |> Map.new()
  end

  # When the listed season holds no row of the file but several other seasons
  # do, one of them moves and the rest are ghosts of it. The row that moves is
  # one a watch-party room points at when there is one, and the oldest
  # otherwise. Each ghost is paired with the row that survives it.
  defp plan_reconciliation(misplaced, with_rooms) do
    Enum.reduce(misplaced, {[], []}, fn
      {target, [], elsewhere}, {moves, ghosts} ->
        [mover | rest] =
          Enum.sort_by(
            elsewhere,
            &{not MapSet.member?(with_rooms, &1.catalog_item_id), &1.id}
          )

        {[{target, mover} | moves], Enum.map(rest, &{target, &1, mover}) ++ ghosts}

      {target, [survivor | _], elsewhere}, {moves, ghosts} ->
        {moves, Enum.map(elsewhere, &{target, &1, survivor}) ++ ghosts}
    end)
  end

  defp move_rows(_series, []), do: :ok

  defp move_rows(series, moves) do
    moves
    |> Enum.group_by(fn {target, _row} -> target.id end, fn {_target, row} -> row.id end)
    |> Enum.each(fn {season_id, ids} ->
      from(episode in Episode,
        where: episode.id in ^ids,
        update: [set: [season_id: ^season_id, episode_num: fragment("- ?", episode.id)]]
      )
      |> Repo.update_all([])
    end)

    Logger.info(
      "[GIndex Ingest] series #{series.id}: moved #{length(moves)} file(s) to the season " <>
        "their listing now names, keeping their rows: " <>
        Enum.map_join(Enum.take(moves, 5), " | ", fn {target, row} ->
          "#{episode_label(row)} #{row.season_number}->#{target.season_number}"
        end)
    )
  end

  defp drop_ghosts(_series, [], _with_rooms), do: :ok

  defp drop_ghosts(series, ghosts, with_rooms) do
    {kept, deletable} =
      Enum.split_with(ghosts, fn {_target, row, _survivor} ->
        MapSet.member?(with_rooms, row.catalog_item_id)
      end)

    Enum.each(kept, fn {target, row, _survivor} ->
      Logger.warning(
        "[GIndex Ingest] series #{series.id} (#{series.name}): #{episode_label(row)} is " <>
          "listed only in season #{target.season_number}, which already holds it, but an " <>
          "older row in season #{row.season_number} has a watch-party room; kept for review " <>
          "(episode row #{row.id}, catalog item #{row.catalog_item_id})"
      )
    end)

    if deletable != [] do
      ids = Enum.map(deletable, fn {_target, row, _survivor} -> row.id end)

      deletable
      |> Enum.map(fn {_target, row, survivor} ->
        {row.catalog_item_id, survivor.catalog_item_id}
      end)
      |> CatalogItemRedirect.record()

      Repo.delete_all(from(episode in Episode, where: episode.id in ^ids))

      Logger.info(
        "[GIndex Ingest] series #{series.id}: dropped #{length(ids)} duplicate row(s) of " <>
          "files now filed in another season: " <>
          Enum.map_join(Enum.take(deletable, 5), " | ", fn {target, row, _survivor} ->
            "#{episode_label(row)} #{row.season_number}->#{target.season_number}"
          end)
      )
    end

    :ok
  end

  defp series_episode_rows(_series_id, []), do: []

  defp series_episode_rows(series_id, episode_ids) do
    from(episode in Episode,
      join: season in assoc(episode, :season),
      where: season.series_id == ^series_id and episode.episode_id in ^episode_ids,
      select: %{
        id: episode.id,
        episode_id: episode.episode_id,
        catalog_item_id: episode.catalog_item_id,
        season_id: episode.season_id,
        season_number: season.season_number,
        name: episode.name,
        gindex_path: episode.gindex_path
      }
    )
    |> Repo.all()
  end

  defp episode_label(row), do: row.gindex_path || row.name || "episode #{row.episode_id}"

  defp upsert_season(series_id, attrs) do
    attrs = attrs |> Map.take(@season_fields) |> Map.put(:series_id, series_id)
    season_number = Map.fetch!(attrs, :season_number)

    case Repo.one(
           from(season in Season,
             where: season.series_id == ^series_id and season.season_number == ^season_number
           )
         ) do
      nil ->
        %Season{}
        |> Season.changeset(attrs)
        |> Repo.insert!()

      season ->
        season
        |> Season.changeset(attrs)
        |> Repo.update!()
    end
  end

  # `episodes` carries two competing unique indexes, on (season_id, episode_num)
  # and on (season_id, episode_id), and an upsert may name only one of them as
  # its conflict target. Keying everything on episode_num meant a file whose
  # number changed looked new, so the insert collided with that file's own
  # existing row on the episode_id index and aborted the whole scan root.
  #
  # Numbers do change. The filename parser learned to read `SxxEyy` and `1x01`,
  # so files previously scored by the digit-run fallback are renumbered on the
  # next sync — in production that took out /0:/Desenhos/ and
  # /1:/Séries/Séries Misturado/ on every attempt for four days.
  #
  # So split by what identifies the row: a file already stored in this season
  # keeps its row and only moves number; everything else is matched by number
  # as before. A row `reconcile_seasons/2` just moved in from another season is
  # found here the same way, parked at `- id`, and unparked by the upsert.
  #
  # `episodes` must already have been through `dedupe_episodes/2`.
  defp upsert_episodes(season_id, episodes, provider_id, now) do
    existing = existing_episodes(season_id)

    {renumbered, fresh} =
      Enum.split_with(episodes, &Map.has_key?(existing.by_id, Map.fetch!(&1, :episode_id)))

    stale = stale_blockers(existing, renumbered, episodes)
    drop_stale(stale)

    # A renumbered file takes its catalog item with it. Without holding it back,
    # a different file arriving at the number it vacated would be handed the
    # same catalog item and break the unique index on catalog_item_id — which is
    # the common shape here, since a season that had collapsed onto one number
    # comes back with a full set of episodes.
    claimed = MapSet.new(renumbered, &Map.fetch!(existing.by_id, Map.fetch!(&1, :episode_id)))
    discarded = MapSet.new(stale, & &1.catalog_item_id)

    reusable_by_number =
      Map.reject(existing.by_number, fn {_number, item_id} ->
        MapSet.member?(claimed, item_id) or MapSet.member?(discarded, item_id)
      end)

    new_episodes =
      Enum.reject(fresh, &Map.has_key?(reusable_by_number, Map.fetch!(&1, :episode_num)))

    new_catalog_item_ids =
      Helpers.pre_create_catalog_items(length(new_episodes), "episode", provider_id, now)

    new_catalog_items =
      new_episodes
      |> Enum.map(&episode_key/1)
      |> Enum.zip(new_catalog_item_ids)
      |> Map.new()

    renumbered_entries =
      Enum.map(renumbered, fn episode ->
        catalog_item_id = Map.fetch!(existing.by_id, Map.fetch!(episode, :episode_id))
        episode_entry(episode, season_id, catalog_item_id, now)
      end)

    fresh_entries =
      Enum.map(fresh, fn episode ->
        catalog_item_id =
          reusable_by_number[Map.fetch!(episode, :episode_num)] ||
            Map.fetch!(new_catalog_items, episode_key(episode))

        episode_entry(episode, season_id, catalog_item_id, now)
      end)

    park_renumbered(existing, renumbered)

    replace_renumbered(renumbered_entries) + insert_by_number(fresh_entries)
  end

  # Two files in one season can still resolve to the same number, and in this
  # catalogue that is ordinary rather than wrong: a title folder keeps several
  # releases of the same episode side by side. Measured on
  # /1:/Séries/Séries Misturado/This Is Us/, 180 files reduce to 106 distinct
  # season/episode pairs. The unique index permits one row per pair, so the
  # rest have to go.
  #
  # Reported at info, not warning: it fires for a few hundred seasons every
  # cycle, and a warning for an expected condition only teaches people to stop
  # reading the log. What was wrong before was dropping them in silence, which
  # is how the catalogue lost episodes with no trace.
  #
  # The other unique index needs the same treatment. Two entries carrying one
  # episode_id under different numbers — a `:erlang.phash2/1` collision between
  # two paths, or a listing that returns a file twice and parses it apart —
  # both survived a dedupe by number alone, and the insert then broke
  # (season_id, episode_id) and aborted the series. Deduping by file first
  # keeps the most entries: doing it second could drop a file whose number was
  # only taken by the duplicate that goes anyway.
  defp dedupe_episodes(episodes, season_id) do
    by_file = Enum.uniq_by(episodes, &Map.fetch!(&1, :episode_id))
    deduped = Enum.uniq_by(by_file, &Map.fetch!(&1, :episode_num))

    if length(deduped) < length(episodes) do
      # The multiset difference, not a filter on episode_id: when the listing
      # carries the same file twice, filtering out every id that survived also
      # removed the duplicate that was dropped, and production logged
      # "0 file(s) ... were dropped" for a season that had lost one.
      dropped =
        Enum.map(episodes -- by_file, &describe_drop(&1, "same file")) ++
          Enum.map(by_file -- deduped, &describe_drop(&1, "same number"))

      Logger.info(
        "[GIndex Ingest] season #{season_id}: #{length(dropped)} file(s) collide on an " <>
          "episode number or file already taken and were dropped: " <>
          Enum.join(Enum.take(dropped, 5), " | ")
      )
    end

    deduped
  end

  defp describe_drop(episode, reason) do
    "#{Map.fetch!(episode, :episode_num)}=#{Map.get(episode, :name)} (#{reason})"
  end

  # The one collision neither conflict target can resolve. A renumbered file
  # moves onto a number another row still holds; because that file upserts on
  # episode_id, the row in its way is never visited and Postgres rejects the
  # whole batch on (season_id, episode_num). In production this is what left
  # /0:/Animes/ `failed` and /1:/Séries/Séries Misturado/ retrying for eleven
  # days.
  #
  # Such a row is stale by construction: its own file is no longer in the
  # listing, while the number it occupies now belongs to a file that is. The
  # previous code could repurpose a row like this only when the claimant was a
  # new file, because then (season_id, episode_num) was the conflict target.
  #
  # Deleting it is measured rather than assumed: `episode_assets` and
  # `torrent_streams` are the only tables cascading from episodes.id, and no
  # GIndex episode in production has a row in either.
  defp stale_blockers(existing, renumbered, episodes) do
    incoming_ids = MapSet.new(episodes, &Map.fetch!(&1, :episode_id))
    reassigned = MapSet.new(renumbered, &Map.fetch!(&1, :episode_num))

    Enum.filter(existing.rows, fn row ->
      MapSet.member?(reassigned, row.episode_num) and
        not MapSet.member?(incoming_ids, row.episode_id)
    end)
  end

  defp drop_stale([]), do: :ok

  defp drop_stale(rows) do
    ids = Enum.map(rows, & &1.id)

    Logger.info(
      "[GIndex Ingest] dropping #{length(ids)} stale episode row(s) whose number was " <>
        "reassigned to a file still present upstream"
    )

    Repo.delete_all(from(episode in Episode, where: episode.id in ^ids))
    :ok
  end

  defp episode_entry(episode, season_id, catalog_item_id, now) do
    episode
    |> Map.take(@episode_fields)
    |> Map.merge(%{
      season_id: season_id,
      catalog_item_id: catalog_item_id,
      inserted_at: now,
      updated_at: now
    })
  end

  # Moves the rows whose number is about to change out of the way first, so a
  # season whose numbers merely permute cannot collide with itself partway
  # through the upsert — Postgres checks the unique index row by row, not at the
  # end of the statement. `- id` is distinct per row and can never meet a real
  # episode number, and every parked row is restored by the upsert that follows,
  # because parking is only ever applied to rows that upsert will update.
  defp park_renumbered(existing, renumbered) do
    ids =
      for episode <- renumbered,
          row = Map.fetch!(existing.row_by_id, Map.fetch!(episode, :episode_id)),
          row.episode_num != Map.fetch!(episode, :episode_num),
          do: row.id

    if ids != [] do
      from(episode in Episode,
        where: episode.id in ^ids,
        update: [set: [episode_num: fragment("- ?", episode.id)]]
      )
      |> Repo.update_all([])
    end

    :ok
  end

  defp replace_renumbered([]), do: 0

  defp replace_renumbered(entries) do
    {count, _rows} =
      Repo.insert_all(Episode, entries,
        on_conflict: {:replace, @episode_renumber_fields},
        conflict_target: [:season_id, :episode_id]
      )

    count
  end

  defp insert_by_number([]), do: 0

  defp insert_by_number(entries) do
    {count, _rows} =
      Repo.insert_all(Episode, entries,
        on_conflict: {:replace, @episode_replace_fields},
        conflict_target: [:season_id, :episode_num]
      )

    count
  end

  defp existing_episodes(season_id) do
    rows =
      Episode
      |> where(season_id: ^season_id)
      |> select([episode], %{
        id: episode.id,
        episode_id: episode.episode_id,
        episode_num: episode.episode_num,
        catalog_item_id: episode.catalog_item_id
      })
      |> Repo.all()

    %{
      rows: rows,
      by_id: Map.new(rows, &{&1.episode_id, &1.catalog_item_id}),
      by_number: Map.new(rows, &{&1.episode_num, &1.catalog_item_id}),
      row_by_id: Map.new(rows, &{&1.episode_id, %{id: &1.id, episode_num: &1.episode_num}})
    }
  end

  defp episode_key(episode) do
    {Map.fetch!(episode, :episode_id), Map.fetch!(episode, :episode_num)}
  end
end
