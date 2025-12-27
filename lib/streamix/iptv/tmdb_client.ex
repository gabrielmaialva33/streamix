defmodule Streamix.Iptv.TmdbClient do
  @moduledoc """
  HTTP client for The Movie Database (TMDB) API.

  Used to fetch enriched movie metadata like synopsis, cast, crew,
  trailers, and high-quality images.
  """

  @base_url "https://api.themoviedb.org/3"
  @image_base_url "https://image.tmdb.org/t/p"
  @timeout :timer.seconds(10)

  @doc """
  Checks if TMDB integration is enabled and configured.
  """
  def enabled? do
    config()[:enabled] == true && config()[:api_token] != nil
  end

  @doc """
  Fetches movie details from TMDB by movie ID.
  Returns {:ok, movie_data} or {:error, reason}.

  The movie_data includes:
  - overview (synopsis)
  - credits (cast, crew)
  - videos (trailers)
  - runtime
  - vote_average
  - backdrop_path, poster_path
  """
  def get_movie(tmdb_id) when is_binary(tmdb_id) or is_integer(tmdb_id) do
    if enabled?() do
      url = "#{@base_url}/movie/#{tmdb_id}?append_to_response=credits,videos,release_dates,images&language=pt-BR&include_image_language=null"
      do_request(url)
    else
      {:error, :tmdb_not_configured}
    end
  end

  @doc """
  Fetches TV series details from TMDB by series ID.
  """
  def get_series(tmdb_id) when is_binary(tmdb_id) or is_integer(tmdb_id) do
    if enabled?() do
      url = "#{@base_url}/tv/#{tmdb_id}?append_to_response=credits,videos,content_ratings,images&language=pt-BR&include_image_language=null"
      do_request(url)
    else
      {:error, :tmdb_not_configured}
    end
  end

  @doc """
  Fetches a season with all episodes from TMDB.
  Returns episode details including overview, still_path, air_date, runtime.
  """
  def get_season(series_tmdb_id, season_number)
      when (is_binary(series_tmdb_id) or is_integer(series_tmdb_id)) and is_integer(season_number) do
    if enabled?() do
      url = "#{@base_url}/tv/#{series_tmdb_id}/season/#{season_number}?language=pt-BR"
      do_request(url)
    else
      {:error, :tmdb_not_configured}
    end
  end

  @doc """
  Searches for a movie by title and optionally year.
  """
  def search_movie(query, opts \\ []) do
    if enabled?() do
      year = opts[:year]
      query_encoded = URI.encode_www_form(query)

      url =
        if year do
          "#{@base_url}/search/movie?query=#{query_encoded}&year=#{year}&language=pt-BR"
        else
          "#{@base_url}/search/movie?query=#{query_encoded}&language=pt-BR"
        end

      do_request(url)
    else
      {:error, :tmdb_not_configured}
    end
  end

  @doc """
  Searches for a TV series by title and optionally year.
  Returns {:ok, results} or {:error, reason}.
  """
  def search_series(query, opts \\ []) do
    if enabled?() do
      year = opts[:year]
      query_encoded = URI.encode_www_form(query)

      url =
        if year do
          "#{@base_url}/search/tv?query=#{query_encoded}&first_air_date_year=#{year}&language=pt-BR"
        else
          "#{@base_url}/search/tv?query=#{query_encoded}&language=pt-BR"
        end

      do_request(url)
    else
      {:error, :tmdb_not_configured}
    end
  end

  @doc """
  Builds a full image URL from a TMDB image path.

  Sizes:
  - poster: w92, w154, w185, w342, w500, w780, original
  - backdrop: w300, w780, w1280, original
  """
  def image_url(path, size \\ "w500")
  def image_url(nil, _size), do: nil
  def image_url("", _size), do: nil

  def image_url(path, size) do
    "#{@image_base_url}/#{size}#{path}"
  end

  @doc """
  Parses TMDB movie response into attributes suitable for our Movie schema.
  """
  def parse_movie_response(%{"id" => _} = data) do
    %{}
    |> maybe_put(:plot, data["overview"])
    |> maybe_put(:rating, parse_rating(data["vote_average"]))
    |> maybe_put(:duration, format_runtime(data["runtime"]))
    |> maybe_put(:duration_secs, parse_runtime_secs(data["runtime"]))
    |> maybe_put(:genre, parse_genres(data["genres"]))
    |> maybe_put(:year, parse_year(data["release_date"]))
    |> maybe_put(:director, parse_director(data["credits"]))
    |> maybe_put(:cast, parse_cast(data["credits"]))
    |> maybe_put(:youtube_trailer, parse_trailer(data["videos"]))
    |> maybe_put(:backdrop_path, parse_backdrop_paths(data["backdrop_path"]))
    |> maybe_put(:stream_icon, image_url(data["poster_path"], "w500"))
    |> maybe_put(:tagline, data["tagline"])
    |> maybe_put(:content_rating, parse_content_rating(data["release_dates"]))
    |> maybe_put(:images, parse_images(data["images"]))
  end

  def parse_movie_response(_), do: %{}

  @doc """
  Parses TMDB series response into attributes suitable for our Series schema.
  """
  def parse_series_response(%{"id" => _} = data) do
    %{}
    |> maybe_put(:plot, data["overview"])
    |> maybe_put(:rating, parse_rating(data["vote_average"]))
    |> maybe_put(:genre, parse_genres(data["genres"]))
    |> maybe_put(:year, parse_year(data["first_air_date"]))
    |> maybe_put(:director, parse_creators(data["created_by"]))
    |> maybe_put(:cast, parse_cast(data["credits"]))
    |> maybe_put(:youtube_trailer, parse_trailer(data["videos"]))
    |> maybe_put(:backdrop_path, parse_backdrop_paths(data["backdrop_path"]))
    |> maybe_put(:cover, image_url(data["poster_path"], "w500"))
    |> maybe_put(:tagline, data["tagline"])
    |> maybe_put(:content_rating, parse_series_content_rating(data["content_ratings"]))
    |> maybe_put(:images, parse_images(data["images"]))
  end

  def parse_series_response(_), do: %{}

  @doc """
  Parses TMDB season response and returns a map of episode_num => episode_attrs.
  This allows matching with our episodes by episode number.
  """
  def parse_season_episodes(%{"episodes" => episodes}) when is_list(episodes) do
    episodes
    |> Enum.map(fn ep ->
      {ep["episode_number"], parse_episode_response(ep)}
    end)
    |> Enum.into(%{})
  end

  def parse_season_episodes(_), do: %{}

  @doc """
  Parses a single TMDB episode into attributes suitable for our Episode schema.
  """
  def parse_episode_response(%{"id" => tmdb_id} = data) do
    %{}
    |> maybe_put(:tmdb_id, tmdb_id)
    |> maybe_put(:name, data["name"])
    |> maybe_put(:plot, data["overview"])
    |> maybe_put(:rating, parse_rating(data["vote_average"]))
    |> maybe_put(:still_path, image_url(data["still_path"], "w500"))
    |> maybe_put(:air_date, parse_date(data["air_date"]))
    |> maybe_put(:duration_secs, parse_runtime_secs(data["runtime"]))
    |> maybe_put(:duration, format_runtime(data["runtime"]))
    |> Map.put(:tmdb_enriched, true)
  end

  def parse_episode_response(_), do: %{}

  # ============================================================================
  # Private
  # ============================================================================

  @max_retries 3
  @initial_backoff 1000

  defp do_request(url, retries \\ 0) do
    headers = [
      {"Authorization", "Bearer #{config()[:api_token]}"},
      {"Accept", "application/json"}
    ]

    url
    |> Req.get(headers: headers, receive_timeout: @timeout)
    |> handle_response(url, retries)
  end

  defp handle_response({:ok, %{status: 200, body: body}}, _url, _retries) when is_map(body) do
    {:ok, body}
  end

  defp handle_response({:ok, %{status: 200, body: body}}, _url, _retries) when is_binary(body) do
    Jason.decode(body)
  end

  defp handle_response({:ok, %{status: 429} = response}, url, retries) when retries < @max_retries do
    retry_after = get_retry_after(response)
    Process.sleep(retry_after)
    do_request(url, retries + 1)
  end

  defp handle_response({:ok, %{status: 429}}, _url, _retries), do: {:error, :rate_limited}
  defp handle_response({:ok, %{status: 404}}, _url, _retries), do: {:error, :not_found}
  defp handle_response({:ok, %{status: 401}}, _url, _retries), do: {:error, :unauthorized}
  defp handle_response({:ok, %{status: status}}, _url, _retries), do: {:error, {:http_error, status}}
  defp handle_response({:error, %Req.TransportError{reason: reason}}, _url, _retries), do: {:error, {:transport_error, reason}}
  defp handle_response({:error, reason}, _url, _retries), do: {:error, reason}

  defp get_retry_after(%{headers: headers}) do
    # Try to get Retry-After header, otherwise use exponential backoff
    case List.keyfind(headers, "retry-after", 0) do
      {"retry-after", seconds} ->
        String.to_integer(seconds) * 1000

      _ ->
        @initial_backoff
    end
  rescue
    _ -> @initial_backoff
  end

  defp get_retry_after(_), do: @initial_backoff

  defp config do
    Application.get_env(:streamix, :tmdb, [])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_rating(nil), do: nil
  defp parse_rating(0), do: nil
  defp parse_rating(vote_average) when vote_average == 0.0, do: nil

  defp parse_rating(vote_average) when is_number(vote_average) do
    # TMDB uses 0-10 scale, we store as-is (will be converted to 5-scale in display)
    Decimal.from_float(vote_average * 1.0)
  end

  defp parse_rating(_), do: nil

  defp format_runtime(nil), do: nil
  defp format_runtime(0), do: nil

  defp format_runtime(minutes) when is_integer(minutes) do
    hours = div(minutes, 60)
    mins = rem(minutes, 60)
    if hours > 0, do: "#{hours}h #{mins}min", else: "#{mins}min"
  end

  defp format_runtime(_), do: nil

  defp parse_runtime_secs(nil), do: nil
  defp parse_runtime_secs(0), do: nil
  defp parse_runtime_secs(minutes) when is_integer(minutes), do: minutes * 60
  defp parse_runtime_secs(_), do: nil

  defp parse_genres(nil), do: nil
  defp parse_genres([]), do: nil

  defp parse_genres(genres) when is_list(genres) do
    genres
    |> Enum.take(3)
    |> Enum.map_join(", ", & &1["name"])
  end

  defp parse_genres(_), do: nil

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

  defp parse_director(nil), do: nil

  defp parse_director(%{"crew" => crew}) when is_list(crew) do
    result =
      crew
      |> Enum.filter(&(&1["job"] == "Director"))
      |> Enum.take(2)
      |> Enum.map_join(", ", & &1["name"])

    if result == "", do: nil, else: result
  end

  defp parse_director(_), do: nil

  # Parse series creators (equivalent to directors for TV shows)
  defp parse_creators(nil), do: nil
  defp parse_creators([]), do: nil

  defp parse_creators(creators) when is_list(creators) do
    result =
      creators
      |> Enum.take(2)
      |> Enum.map_join(", ", & &1["name"])

    if result == "", do: nil, else: result
  end

  defp parse_creators(_), do: nil

  defp parse_cast(nil), do: nil

  defp parse_cast(%{"cast" => cast}) when is_list(cast) do
    result =
      cast
      |> Enum.take(5)
      |> Enum.map_join(", ", & &1["name"])

    if result == "", do: nil, else: result
  end

  defp parse_cast(_), do: nil

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
        # Fallback: any YouTube video
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

  defp parse_backdrop_paths(nil), do: nil
  defp parse_backdrop_paths(""), do: nil

  defp parse_backdrop_paths(path) when is_binary(path) do
    [image_url(path, "w1280")]
  end

  defp parse_backdrop_paths(_), do: nil

  # Parse content rating from release_dates
  # Prioritizes BR, then US, then any other country
  defp parse_content_rating(nil), do: nil

  defp parse_content_rating(%{"results" => results}) when is_list(results) do
    # Try to find Brazilian rating first
    br_rating = find_certification(results, "BR")
    us_rating = find_certification(results, "US")

    cond do
      br_rating -> br_rating
      us_rating -> us_rating
      true -> find_first_certification(results)
    end
  end

  defp parse_content_rating(_), do: nil

  # Parse content rating for TV series from content_ratings endpoint
  # Structure: {"results": [{"iso_3166_1": "BR", "rating": "16"}, ...]}
  defp parse_series_content_rating(nil), do: nil

  defp parse_series_content_rating(%{"results" => results}) when is_list(results) do
    # Try to find Brazilian rating first
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

  # Parse images gallery (backdrops and posters)
  defp parse_images(nil), do: nil

  defp parse_images(%{"backdrops" => backdrops, "posters" => posters}) do
    backdrop_urls =
      (backdrops || [])
      |> Enum.take(6)
      |> Enum.map(&image_url(&1["file_path"], "w780"))

    poster_urls =
      (posters || [])
      |> Enum.take(4)
      |> Enum.map(&image_url(&1["file_path"], "w500"))

    images = backdrop_urls ++ poster_urls

    if Enum.empty?(images), do: nil, else: images
  end

  defp parse_images(_), do: nil
end
