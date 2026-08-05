defmodule Streamix.Iptv.Content.SeriesOps.Enrichment do
  @moduledoc false

  alias Streamix.Iptv.{
    Episode,
    Series,
    SeriesAsset,
    TmdbClient
  }

  alias Streamix.Repo

  @detail_preloads [:assets, :genres, credits: :person]

  @spec fetch_info(Series.t()) :: {:ok, Series.t()} | {:error, term()}
  def fetch_info(%Series{} = series) do
    series = Repo.preload(series, @detail_preloads)
    profile = tmdb_profile(series)
    tmdb_id = series.tmdb_id || resolve_series_tmdb_id(series, profile)

    if needs_tmdb_enrichment?(series) and is_binary(tmdb_id) and tmdb_id != "" do
      case TmdbClient.get_series(tmdb_id, profile: profile) do
        {:ok, data} ->
          attrs =
            data
            |> TmdbClient.parse_series_response()
            |> maybe_put_tmdb_id(series.tmdb_id, tmdb_id)

          update_series(series, attrs)

        {:error, _reason} ->
          {:ok, series}
      end
    else
      {:ok, series}
    end
  end

  @spec fetch_episode_info(Episode.t()) :: {:ok, Episode.t()} | {:error, term()}
  def fetch_episode_info(%Episode{} = episode) do
    episode = Repo.preload(episode, season: :series)
    series = episode.season.series
    tmdb_id = series.tmdb_id
    season_number = episode.season.season_number

    if needs_episode_tmdb_enrichment?(episode) and is_binary(tmdb_id) and tmdb_id != "" do
      fetch_and_update_episode(episode, tmdb_id, season_number, tmdb_profile(series))
    else
      {:ok, episode}
    end
  end

  @spec persist_series_assets(integer(), String.t(), nil | [String.t()]) :: :ok
  def persist_series_assets(_series_id, _type, nil), do: :ok
  def persist_series_assets(_series_id, _type, []), do: :ok

  def persist_series_assets(series_id, type, urls) when is_list(urls) do
    now = DateTime.utc_now(:second)

    entries =
      urls
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.with_index()
      |> Enum.map(fn {url, idx} ->
        %{
          series_id: series_id,
          asset_type: type,
          url: url,
          position: idx,
          inserted_at: now,
          updated_at: now
        }
      end)

    case entries do
      [] ->
        :ok

      _ ->
        Repo.insert_all(SeriesAsset, entries,
          on_conflict: :nothing,
          conflict_target: [:series_id, :asset_type, :url]
        )
    end

    :ok
  end

  defp tmdb_profile(%Series{gindex_path: path}) when is_binary(path) and path != "",
    do: :gindex

  defp tmdb_profile(_series), do: :default

  defp resolve_series_tmdb_id(%Series{} = series, profile) do
    title = series.title || series.name

    if is_binary(title) and title != "" do
      with {:ok, %{"results" => results}} when is_list(results) <-
             TmdbClient.search_series(title, year: series.year, profile: profile),
           %{"id" => id} <-
             Enum.find(results, &year_matches?(&1["first_air_date"], series.year)) do
        to_string(id)
      else
        _ -> nil
      end
    else
      nil
    end
  end

  defp year_matches?(_air_date, nil), do: true
  defp year_matches?(nil, _year), do: false
  defp year_matches?("", _year), do: false

  defp year_matches?(air_date, year) when is_binary(air_date) and is_integer(year) do
    case Integer.parse(air_date) do
      {result_year, _} -> abs(result_year - year) <= 1
      :error -> false
    end
  end

  defp year_matches?(_, _), do: false

  defp maybe_put_tmdb_id(attrs, existing, resolved)
       when is_nil(existing) or existing == "",
       do: Map.put(attrs, :tmdb_id, resolved)

  defp maybe_put_tmdb_id(attrs, _existing, _resolved), do: attrs

  defp needs_tmdb_enrichment?(series) do
    missing_plot = is_nil(series.plot)
    credits = series.credits || []
    missing_cast = Enum.empty?(Enum.filter(credits, &(&1.role == "cast")))
    missing_director = Enum.empty?(Enum.filter(credits, &(&1.role == "director")))

    missing_extended =
      is_nil(series.content_rating) and is_nil(series.tagline) and
        not Series.has_images?(series)

    missing_plot or missing_cast or missing_director or missing_extended
  end

  defp update_series(series, attrs) when attrs == %{}, do: {:ok, series}

  defp update_series(series, attrs) do
    {backdrops, attrs} = Map.pop(attrs, :_backdrop_urls, [])
    {images, attrs} = Map.pop(attrs, :_image_urls, [])

    with {:ok, updated} <- series |> Series.changeset(attrs) |> Repo.update() do
      persist_series_assets(updated.id, "backdrop", backdrops)
      persist_series_assets(updated.id, "image", images)
      {:ok, updated}
    end
  end

  defp needs_episode_tmdb_enrichment?(episode) do
    not episode.tmdb_enriched
  end

  defp fetch_and_update_episode(episode, tmdb_id, season_number, profile) do
    case TmdbClient.get_season(tmdb_id, season_number, profile: profile) do
      {:ok, data} ->
        data
        |> TmdbClient.parse_season_episodes()
        |> Map.get(episode.episode_num)
        |> case do
          nil -> {:ok, episode}
          attrs -> update_episode(episode, attrs)
        end

      {:error, _reason} ->
        {:ok, episode}
    end
  end

  defp update_episode(episode, attrs) when attrs == %{}, do: {:ok, episode}

  defp update_episode(episode, attrs) do
    episode
    |> Episode.changeset(attrs)
    |> Repo.update()
  end
end
