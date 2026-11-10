defmodule Streamix.Iptv.TmdbClient.Parser do
  @moduledoc false

  alias Streamix.Iptv.TmdbClient.Transport

  def parse_movie_response(%{"id" => _} = data) do
    {gallery_backdrops, gallery_posters} = parse_images_gallery(data["images"])

    %{}
    |> maybe_put(:tmdb_genre_ids, parse_genre_ids(data["genres"]))
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
    |> maybe_put(:tmdb_genre_ids, parse_genre_ids(data["genres"]))
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

  @cast_limit 10
  @crew_limit 3
  @writing_jobs ~w(Screenplay Writer Novel Story Author Book)

  @type keyword_tag :: %{id: pos_integer(), name: String.t()}
  @type credit :: %{
          name: String.t(),
          role: String.t(),
          position: non_neg_integer()
        }
  @type metadata :: %{
          genre_ids: [pos_integer()] | nil,
          keywords: [keyword_tag()],
          credits: [credit()]
        }

  @doc """
  Genre ids, keywords and the credits worth searching by, from a detail
  response with `keywords,credits` appended. `genre_ids` is nil when the
  answer carries no genre list at all.

  Credits keep the billed cast (top #{@cast_limit}), directors and writers;
  a series' creators count as its writers. Keyword names are TMDB's English
  labels, which is the only language TMDB publishes them in.
  """
  @spec metadata(:movie | :tv, map()) :: metadata()
  def metadata(kind, data) when kind in [:movie, :tv] and is_map(data) do
    %{
      genre_ids: parse_genre_ids(data["genres"]),
      keywords: parse_keywords(keyword_list(kind, data["keywords"])),
      credits: parse_credits(data["credits"], data["created_by"])
    }
  end

  # Movies list them under "keywords", series under "results".
  defp keyword_list(:movie, %{"keywords" => list}), do: list
  defp keyword_list(:tv, %{"results" => list}), do: list
  defp keyword_list(_kind, _keywords), do: []

  defp parse_keywords(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      %{"id" => id, "name" => name} when is_integer(id) and id > 0 and is_binary(name) ->
        case String.trim(name) do
          "" -> []
          name -> [%{id: id, name: name}]
        end

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp parse_keywords(_list), do: []

  defp parse_credits(credits, created_by) do
    credits = if is_map(credits), do: credits, else: %{}
    crew = list_or_empty(credits["crew"])

    cast =
      credits["cast"]
      |> list_or_empty()
      |> Enum.sort_by(&order_of/1)
      |> names()
      |> Enum.take(@cast_limit)

    directors = crew |> Enum.filter(&(&1["job"] == "Director")) |> names()

    writers =
      list_or_empty(created_by) ++
        Enum.filter(crew, &(&1["department"] == "Writing" and &1["job"] in @writing_jobs))

    role_credits("cast", cast) ++
      role_credits("director", Enum.take(directors, @crew_limit)) ++
      role_credits("writer", writers |> names() |> Enum.take(@crew_limit))
  end

  defp role_credits(role, names) do
    names
    |> Enum.with_index()
    |> Enum.map(fn {name, position} -> %{name: name, role: role, position: position} end)
  end

  # Trimmed, non-blank names in order, first occurrence wins.
  defp names(people) do
    people
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) ->
        case String.trim(name) do
          "" -> []
          name -> [name]
        end

      _ ->
        []
    end)
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp order_of(%{"order" => order}) when is_integer(order), do: order
  defp order_of(_person), do: 1_000_000

  defp list_or_empty(list) when is_list(list), do: list
  defp list_or_empty(_value), do: []

  defp parse_genre_ids(genres) when is_list(genres) do
    genres
    |> Enum.flat_map(fn
      %{"id" => id} when is_integer(id) and id > 0 -> [id]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp parse_genre_ids(_), do: nil

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
