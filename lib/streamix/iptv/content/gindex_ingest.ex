defmodule Streamix.Iptv.Content.GindexIngest do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{CatalogItem, Episode, Movie, Season, Series}
  alias Streamix.Iptv.Sync.Helpers
  alias Streamix.Repo

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

  defp sync_seasons(series, seasons, provider_id, now) do
    Enum.reduce(seasons, 0, fn season_content, episode_count ->
      season = upsert_season(series.id, Map.fetch!(season_content, :season))

      episode_count +
        upsert_episodes(
          season.id,
          Map.fetch!(season_content, :episodes),
          provider_id,
          now
        )
    end)
  end

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
  # as before.
  defp upsert_episodes(season_id, episodes, provider_id, now) do
    episodes = Enum.uniq_by(episodes, &Map.fetch!(&1, :episode_num))
    existing = existing_episodes(season_id)

    {renumbered, fresh} =
      Enum.split_with(episodes, &Map.has_key?(existing.by_id, Map.fetch!(&1, :episode_id)))

    # A renumbered file takes its catalog item with it. Without holding it back,
    # a different file arriving at the number it vacated would be handed the
    # same catalog item and break the unique index on catalog_item_id — which is
    # the common shape here, since a season that had collapsed onto one number
    # comes back with a full set of episodes.
    claimed = MapSet.new(renumbered, &Map.fetch!(existing.by_id, Map.fetch!(&1, :episode_id)))

    reusable_by_number =
      Map.reject(existing.by_number, fn {_number, item_id} -> MapSet.member?(claimed, item_id) end)

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
      |> select([episode], {
        episode.id,
        episode.episode_id,
        episode.episode_num,
        episode.catalog_item_id
      })
      |> Repo.all()

    %{
      by_id:
        Map.new(rows, fn {_id, episode_id, _episode_number, catalog_item_id} ->
          {episode_id, catalog_item_id}
        end),
      by_number:
        Map.new(rows, fn {_id, _episode_id, episode_number, catalog_item_id} ->
          {episode_number, catalog_item_id}
        end),
      row_by_id:
        Map.new(rows, fn {id, episode_id, episode_number, _catalog_item_id} ->
          {episode_id, %{id: id, episode_num: episode_number}}
        end)
    }
  end

  defp episode_key(episode) do
    {Map.fetch!(episode, :episode_id), Map.fetch!(episode, :episode_num)}
  end
end
