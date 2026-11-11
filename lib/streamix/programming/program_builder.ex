defmodule Streamix.Programming.ProgramBuilder do
  @moduledoc """
  Turns a station into a program, in an order shuffled per station and per
  day so the same titles do not always open the loop.

    * A `"movies"` station runs discovery over the public Xtream providers
      (every viewer may play them) and keeps titles the public catalog still
      lists with a real feature runtime.
    * A `"series"` station takes, for each of its TMDB series, the public
      copy with the most episodes (fetching them from the provider when none
      are stored yet, as the series page does) and picks random episodes.
      A marathon takes at most 80 episodes of each series, so a long-running
      show cannot crowd out the rest.
  """

  alias Streamix.{AI, Catalog, Providers}
  alias Streamix.Programming.Station

  @candidates 80
  @max_movies 40
  @min_items 5
  @min_runtime 60 * 60
  @max_runtime 4 * 60 * 60

  @max_episodes 200
  @per_series 80
  @copies_tried 3
  # Used when none of a series' episodes knows its runtime.
  @default_episode_runtime 25 * 60
  @min_episode_runtime 5 * 60
  @max_episode_runtime 2 * 60 * 60

  @doc "A program for the station, or an error when its sources yield too little."
  @spec build(Station.t(), Date.t()) :: {:ok, [map()]} | {:error, term()}
  def build(%Station{kind: "series"} = station, %Date{} = day) do
    per_series = if length(station.series_tmdb_ids) > 1, do: @per_series, else: @max_episodes

    station.series_tmdb_ids
    |> Enum.flat_map(fn tmdb_id ->
      tmdb_id
      |> series_episodes()
      |> shuffle({station.slug, tmdb_id, day})
      |> Enum.take(per_series)
    end)
    |> shuffle({station.slug, day})
    |> Enum.take(@max_episodes)
    |> enough()
  end

  def build(%Station{} = station, %Date{} = day) do
    with [_ | _] = provider_ids <- public_provider_ids(),
         {:ok, %{results: results}} <-
           AI.discover(station.query, :movies, provider_ids: provider_ids, limit: @candidates) do
      results
      |> Enum.map(& &1.id)
      |> Catalog.list_public_movies_by_ids(show_adult: false)
      |> Enum.filter(&feature_runtime?/1)
      |> Enum.take(@max_movies)
      |> shuffle({station.slug, day})
      |> Enum.map(&movie_item/1)
      |> enough()
    else
      [] -> {:error, :no_public_providers}
      {:error, _reason} = error -> error
    end
  end

  # --- Movies ---

  defp public_provider_ids do
    for %{provider_type: :xtream, is_active: true, id: id} <- Providers.list_public_providers(),
        do: id
  end

  defp feature_runtime?(%{duration_secs: secs}) when is_integer(secs),
    do: secs >= @min_runtime and secs <= @max_runtime

  defp feature_runtime?(_movie), do: false

  defp movie_item(movie) do
    %{
      "type" => "movie",
      "content_id" => movie.id,
      "duration" => movie.duration_secs,
      "title" => movie.title || movie.name,
      "year" => known_year(movie.year),
      "poster" => movie.stream_icon
    }
  end

  defp known_year(year) when is_integer(year) and year > 0, do: year
  defp known_year(_year), do: nil

  # --- Series ---

  # The best-stocked copy first; a copy whose provider cannot list its
  # episodes right now gives way to the next one.
  defp series_episodes(tmdb_id) do
    tmdb_id
    |> Catalog.public_series_copy_ids_by_tmdb()
    |> Enum.take(@copies_tried)
    |> Enum.find_value([], fn id ->
      case id |> Catalog.get_series_with_sync!() |> episode_items() do
        [] -> nil
        items -> items
      end
    end)
  end

  defp episode_items(series) do
    episodes = for season <- series.seasons, episode <- season.episodes, do: {season, episode}
    fallback = typical_runtime(Enum.map(episodes, fn {_season, episode} -> episode end))
    title = series.title || series.name

    Enum.map(episodes, fn {season, episode} ->
      %{
        "type" => "episode",
        "content_id" => episode.id,
        "duration" => runtime(episode) || fallback,
        "title" => title,
        "subtitle" => episode_label(season, episode),
        "year" => nil,
        "poster" => series.cover
      }
    end)
  end

  defp runtime(%{duration_secs: secs})
       when is_integer(secs) and secs >= @min_episode_runtime and secs <= @max_episode_runtime,
       do: secs

  defp runtime(_episode), do: nil

  # The median known runtime of the series stands in for episodes without one.
  defp typical_runtime(episodes) do
    case episodes |> Enum.flat_map(&List.wrap(runtime(&1))) |> Enum.sort() do
      [] -> @default_episode_runtime
      known -> Enum.at(known, div(length(known), 2))
    end
  end

  defp episode_label(season, episode) do
    number = "T#{season.season_number}:E#{episode.episode_num}"

    case episode.title || episode.name do
      name when is_binary(name) and name != "" -> "#{number} · #{name}"
      _none -> number
    end
  end

  # --- Shared ---

  # Deterministic per seed: a rebuild on the same day keeps the order, the
  # next day's rebuild reshuffles it.
  defp shuffle(items, seed) do
    hash = :erlang.phash2(seed)
    state = :rand.seed_s(:exsss, {hash, hash * 7 + 1, hash * 13 + 3})

    {keyed, _state} =
      Enum.map_reduce(items, state, fn item, state ->
        {roll, state} = :rand.uniform_s(state)
        {{roll, item}, state}
      end)

    keyed |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
  end

  defp enough(items) when length(items) >= @min_items, do: {:ok, items}
  defp enough(_items), do: {:error, :too_few_titles}
end
