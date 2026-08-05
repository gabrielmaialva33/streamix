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

  defp upsert_episodes(season_id, episodes, provider_id, now) do
    episodes = Enum.uniq_by(episodes, &Map.fetch!(&1, :episode_num))
    existing = existing_episode_catalog_items(season_id)

    new_episodes =
      Enum.reject(episodes, fn episode ->
        Map.has_key?(existing.by_id, Map.fetch!(episode, :episode_id)) or
          Map.has_key?(existing.by_number, Map.fetch!(episode, :episode_num))
      end)

    new_catalog_item_ids =
      Helpers.pre_create_catalog_items(length(new_episodes), "episode", provider_id, now)

    new_catalog_items =
      new_episodes
      |> Enum.map(&episode_key/1)
      |> Enum.zip(new_catalog_item_ids)
      |> Map.new()

    entries =
      Enum.map(episodes, fn episode ->
        catalog_item_id =
          existing.by_id[Map.fetch!(episode, :episode_id)] ||
            existing.by_number[Map.fetch!(episode, :episode_num)] ||
            Map.fetch!(new_catalog_items, episode_key(episode))

        episode
        |> Map.take(@episode_fields)
        |> Map.merge(%{
          season_id: season_id,
          catalog_item_id: catalog_item_id,
          inserted_at: now,
          updated_at: now
        })
      end)

    case entries do
      [] ->
        0

      _entries ->
        {count, _rows} =
          Repo.insert_all(Episode, entries,
            on_conflict: {:replace, @episode_replace_fields},
            conflict_target: [:season_id, :episode_num]
          )

        count
    end
  end

  defp existing_episode_catalog_items(season_id) do
    rows =
      Episode
      |> where(season_id: ^season_id)
      |> select([episode], {
        episode.episode_id,
        episode.episode_num,
        episode.catalog_item_id
      })
      |> Repo.all()

    %{
      by_id:
        Map.new(rows, fn {episode_id, _episode_number, catalog_item_id} ->
          {episode_id, catalog_item_id}
        end),
      by_number:
        Map.new(rows, fn {_episode_id, episode_number, catalog_item_id} ->
          {episode_number, catalog_item_id}
        end)
    }
  end

  defp episode_key(episode) do
    {Map.fetch!(episode, :episode_id), Map.fetch!(episode, :episode_num)}
  end
end
