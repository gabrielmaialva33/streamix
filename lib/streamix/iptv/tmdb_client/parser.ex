defmodule Streamix.Iptv.TmdbClient.Parser do
  @moduledoc false

  alias Streamix.Iptv.TmdbClient.Transport

  def parse_movie_response(%{"id" => _} = data) do
    {gallery_backdrops, gallery_posters} = parse_images_gallery(data["images"])

    %{}
    |> maybe_put(:plot, data["overview"])
    # Private key: only promoted to `:title` when the row has none. See
    # `Content.Movies.Enrichment.update_movie/2`.
    |> maybe_put(:_tmdb_title, data["title"])
    |> maybe_put(:rating, parse_rating(data["vote_average"]))
    |> maybe_put(:duration_secs, parse_runtime_secs(data["runtime"]))
    |> maybe_put(:year, parse_year(data["release_date"]))
    |> maybe_put(:youtube_trailer, parse_trailer(data["videos"]))
    |> maybe_put(:stream_icon, Transport.image_url(data["poster_path"], "w500"))
    |> maybe_put(:tagline, data["tagline"])
    |> maybe_put(:content_rating, parse_content_rating(data["release_dates"]))
    |> maybe_put(:_backdrop_urls, merge_backdrops(data["backdrop_path"], gallery_backdrops))
    |> maybe_put(:_image_urls, nil_if_empty(gallery_posters))
  end

  def parse_movie_response(_), do: %{}

  def parse_series_response(%{"id" => _} = data) do
    {gallery_backdrops, gallery_posters} = parse_images_gallery(data["images"])

    %{}
    |> maybe_put(:plot, data["overview"])
    # TMDB names a TV record with `name`, not `title`. Same private-key rule
    # as movies: fills a blank title, never replaces one.
    |> maybe_put(:_tmdb_title, data["name"])
    |> maybe_put(:rating, parse_rating(data["vote_average"]))
    |> maybe_put(:year, parse_year(data["first_air_date"]))
    |> maybe_put(:youtube_trailer, parse_trailer(data["videos"]))
    |> maybe_put(:cover, Transport.image_url(data["poster_path"], "w500"))
    |> maybe_put(:tagline, data["tagline"])
    |> maybe_put(:content_rating, parse_series_content_rating(data["content_ratings"]))
    |> maybe_put(:_backdrop_urls, merge_backdrops(data["backdrop_path"], gallery_backdrops))
    |> maybe_put(:_image_urls, nil_if_empty(gallery_posters))
  end

  def parse_series_response(_), do: %{}

  def parse_season_episodes(%{"episodes" => episodes}) when is_list(episodes) do
    episodes
    |> Enum.map(fn ep ->
      {ep["episode_number"], parse_episode_response(ep)}
    end)
    |> Enum.into(%{})
  end

  def parse_season_episodes(_), do: %{}

  def parse_episode_response(%{"id" => tmdb_id} = data) do
    %{}
    |> maybe_put(:tmdb_id, tmdb_id)
    |> maybe_put(:name, data["name"])
    |> maybe_put(:plot, data["overview"])
    |> maybe_put(:rating, parse_rating(data["vote_average"]))
    |> maybe_put(:still_path, Transport.image_url(data["still_path"], "w500"))
    |> maybe_put(:air_date, parse_date(data["air_date"]))
    |> maybe_put(:duration_secs, parse_runtime_secs(data["runtime"]))
    |> Map.put(:tmdb_enriched, true)
  end

  def parse_episode_response(_), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_rating(nil), do: nil
  defp parse_rating(0), do: nil
  defp parse_rating(vote_average) when vote_average == 0.0, do: nil

  defp parse_rating(vote_average) when is_number(vote_average) do
    Decimal.from_float(vote_average * 1.0)
  end

  defp parse_rating(_), do: nil

  defp parse_runtime_secs(nil), do: nil
  defp parse_runtime_secs(0), do: nil
  defp parse_runtime_secs(minutes) when is_integer(minutes), do: minutes * 60
  defp parse_runtime_secs(_), do: nil

  defp parse_year(nil), do: nil
  defp parse_year(""), do: nil

  defp parse_year(release_date) when is_binary(release_date) do
    case String.split(release_date, "-") do
      [year | _] -> String.to_integer(year)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp parse_year(_), do: nil

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp parse_trailer(nil), do: nil

  defp parse_trailer(%{"results" => results}) when is_list(results) do
    results
    |> Enum.filter(fn video ->
      video["site"] == "YouTube" &&
        video["type"] in ["Trailer", "Teaser"] &&
        video["official"] == true
    end)
    |> List.first()
    |> case do
      nil ->
        results
        |> Enum.find(&(&1["site"] == "YouTube"))
        |> get_trailer_key()

      video ->
        video["key"]
    end
  end

  defp parse_trailer(_), do: nil

  defp get_trailer_key(nil), do: nil
  defp get_trailer_key(%{"key" => key}), do: key

  defp parse_content_rating(nil), do: nil

  defp parse_content_rating(%{"results" => results}) when is_list(results) do
    br_rating = find_certification(results, "BR")
    us_rating = find_certification(results, "US")

    cond do
      br_rating -> br_rating
      us_rating -> us_rating
      true -> find_first_certification(results)
    end
  end

  defp parse_content_rating(_), do: nil

  defp parse_series_content_rating(nil), do: nil

  defp parse_series_content_rating(%{"results" => results}) when is_list(results) do
    br_rating = find_series_certification(results, "BR")
    us_rating = find_series_certification(results, "US")

    cond do
      br_rating -> br_rating
      us_rating -> us_rating
      true -> find_first_series_certification(results)
    end
  end

  defp parse_series_content_rating(_), do: nil

  defp find_series_certification(results, country_code) do
    results
    |> Enum.find(&(&1["iso_3166_1"] == country_code))
    |> case do
      %{"rating" => rating} when rating != "" and not is_nil(rating) -> rating
      _ -> nil
    end
  end

  defp find_first_series_certification(results) do
    results
    |> Enum.find_value(fn
      %{"rating" => rating} when rating != "" and not is_nil(rating) -> rating
      _ -> nil
    end)
  end

  defp find_certification(results, country_code) do
    results
    |> Enum.find(&(&1["iso_3166_1"] == country_code))
    |> case do
      %{"release_dates" => dates} when is_list(dates) ->
        dates
        |> Enum.find(&(&1["certification"] != "" and &1["certification"] != nil))
        |> case do
          %{"certification" => cert} -> cert
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp find_first_certification(results) do
    results
    |> Enum.find_value(fn %{"release_dates" => dates} ->
      dates
      |> Enum.find(&(&1["certification"] != "" and &1["certification"] != nil))
      |> case do
        %{"certification" => cert} -> cert
        _ -> nil
      end
    end)
  end

  @spec parse_images_gallery(map() | nil) :: {[String.t()], [String.t()]}
  defp parse_images_gallery(nil), do: {[], []}

  defp parse_images_gallery(%{"backdrops" => backdrops, "posters" => posters}) do
    backdrop_urls =
      (backdrops || [])
      |> Enum.take(6)
      |> Enum.map(&Transport.image_url(&1["file_path"], "w780"))
      |> Enum.reject(&is_nil/1)

    poster_urls =
      (posters || [])
      |> Enum.take(4)
      |> Enum.map(&Transport.image_url(&1["file_path"], "w500"))
      |> Enum.reject(&is_nil/1)

    {backdrop_urls, poster_urls}
  end

  defp parse_images_gallery(_), do: {[], []}

  defp merge_backdrops(nil, gallery), do: nil_if_empty(gallery)
  defp merge_backdrops("", gallery), do: nil_if_empty(gallery)

  defp merge_backdrops(path, gallery) when is_binary(path) do
    primary = Transport.image_url(path, "w780")

    (List.wrap(primary) ++ gallery)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> nil_if_empty()
  end

  defp nil_if_empty([]), do: nil
  defp nil_if_empty(list) when is_list(list), do: list
end
