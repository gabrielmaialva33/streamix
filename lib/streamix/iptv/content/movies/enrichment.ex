defmodule Streamix.Iptv.Content.Movies.Enrichment do
  @moduledoc false

  alias Streamix.Iptv.{
    Movie,
    MovieAsset,
    TmdbClient,
    XtreamClient
  }

  alias Streamix.Repo

  # Only Xtream providers expose a VOD info API. Torrent/GIndex movies
  # carry no credentials, so calling XtreamClient with nil user/pass
  # crashed `build_url` (URI.encode_www_form(nil)). Skip straight to the
  # TMDB enrichment path instead.
  def fetch_xtream_attrs(%Movie{provider: %{provider_type: :xtream} = provider} = movie) do
    case XtreamClient.get_vod_info(
           provider.url,
           provider.username,
           provider.password,
           movie.stream_id,
           provider_id: provider.id,
           allow_private_network: provider.is_system
         ) do
      {:ok, %{"info" => info, "movie_data" => movie_data}} ->
        parse_vod_info(info, movie_data)

      {:ok, %{"info" => info}} ->
        parse_vod_info(info, %{})

      {:ok, response} ->
        require Logger

        Logger.debug("[IPTV] Unexpected Xtream response format for movie #{movie.id}",
          response_keys: Map.keys(response)
        )

        %{}

      {:error, reason} ->
        require Logger

        Logger.warning("[IPTV] Xtream API failed for movie #{movie.id}",
          movie_name: movie.name,
          reason: inspect(reason)
        )

        %{}
    end
  end

  def fetch_xtream_attrs(%Movie{}), do: %{}

  def resolve_movie_tmdb_id(%Movie{} = movie) do
    title = movie.title || movie.name

    if is_binary(title) and title != "" do
      with {:ok, %{"results" => results}} when is_list(results) <-
             TmdbClient.search_movie(title, year: movie.year, profile: tmdb_profile(movie)),
           %{"id" => id} <-
             Enum.find(results, &year_matches?(&1["release_date"], movie.year)) do
        to_string(id)
      else
        _ -> nil
      end
    else
      nil
    end
  end

  def maybe_fetch_from_tmdb(movie, xtream_attrs, tmdb_id)
      when is_binary(tmdb_id) and tmdb_id != "" do
    if needs_tmdb_enrichment?(movie, xtream_attrs) do
      fetch_from_tmdb(tmdb_id, tmdb_profile(movie))
    else
      %{}
    end
  end

  def maybe_fetch_from_tmdb(_movie, _xtream_attrs, _tmdb_id), do: %{}

  def update_movie(movie, attrs) when attrs == %{}, do: {:ok, movie}

  def update_movie(movie, attrs) do
    {backdrops, attrs} = Map.pop(attrs, :_backdrop_urls, [])
    {images, attrs} = Map.pop(attrs, :_image_urls, [])
    attrs = promote_tmdb_title(attrs, movie.title)

    with {:ok, updated} <- movie |> Movie.changeset(attrs) |> Repo.update() do
      persist_movie_assets(updated.id, "backdrop", backdrops)
      persist_movie_assets(updated.id, "image", images)
      {:ok, updated}
    end
  end

  def persist_movie_assets(_movie_id, _type, nil), do: :ok
  def persist_movie_assets(_movie_id, _type, []), do: :ok

  def persist_movie_assets(movie_id, type, urls) when is_list(urls) do
    now = DateTime.utc_now(:second)

    entries =
      urls
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.with_index()
      |> Enum.map(fn {url, idx} ->
        %{
          movie_id: movie_id,
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
        Repo.insert_all(MovieAsset, entries,
          on_conflict: :nothing,
          conflict_target: [:movie_id, :asset_type, :url]
        )
    end

    :ok
  end

  # A row with no `title` is displayed by its raw `name` — which for 8.571
  # movies is the release string, extension and all ("A Jornada de Vivo 2021
  # 1080p NF WEB-DL DDP5 1 Atmos x264-PiA"). TMDB's own pt-BR title is already
  # in the response we fetched, so filling the gap costs nothing.
  #
  # Blank titles only. An explicit `:title` in `attrs` is the provider's, and
  # the provider outranks TMDB on its own catalog.
  defp promote_tmdb_title(attrs, current) do
    {tmdb_title, attrs} = Map.pop(attrs, :_tmdb_title)

    if blank?(current) and not blank?(tmdb_title) and not Map.has_key?(attrs, :title) do
      Map.put(attrs, :title, tmdb_title)
    else
      attrs
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp tmdb_profile(%Movie{gindex_path: path}) when is_binary(path) and path != "",
    do: :gindex

  defp tmdb_profile(_movie), do: :default

  defp year_matches?(_release_date, nil), do: true
  defp year_matches?(nil, _year), do: false
  defp year_matches?("", _year), do: false

  defp year_matches?(release_date, year) when is_binary(release_date) and is_integer(year) do
    case Integer.parse(release_date) do
      {result_year, _} -> abs(result_year - year) <= 1
      :error -> false
    end
  end

  defp year_matches?(_, _), do: false

  defp needs_tmdb_enrichment?(movie, xtream_attrs) do
    missing_basic_info?(movie, xtream_attrs) or missing_extended_info?(movie)
  end

  defp missing_basic_info?(movie, xtream_attrs) do
    missing_field?(xtream_attrs[:plot], movie.plot) or
      (is_nil(xtream_attrs[:cast]) and Enum.empty?(movie.credits || [])) or
      (is_nil(xtream_attrs[:director]) and Enum.empty?(movie.credits || []))
  end

  defp missing_extended_info?(movie) do
    is_nil(movie.content_rating) and is_nil(movie.tagline) and not Movie.has_images?(movie)
  end

  defp missing_field?(xtream_val, movie_val), do: is_nil(xtream_val) and is_nil(movie_val)

  defp fetch_from_tmdb(tmdb_id, profile) do
    case TmdbClient.get_movie(tmdb_id, profile: profile) do
      {:ok, data} ->
        TmdbClient.parse_movie_response(data)

      {:error, reason} ->
        require Logger

        Logger.warning(
          "[IPTV] TMDB API failed for tmdb_id #{tmdb_id} (profile=#{profile})",
          reason: inspect(reason)
        )

        %{}

      _ ->
        %{}
    end
  end

  defp parse_vod_info(info, movie_data) when is_map(info) do
    %{}
    |> maybe_put(:title, info["name"])
    |> maybe_put(:plot, info["plot"] || info["description"])
    |> maybe_put(:duration_secs, parse_duration_secs(info["duration_secs"] || info["duration"]))
    |> maybe_put(:rating, parse_decimal(info["rating"]))
    |> maybe_put(:year, parse_integer(info["releasedate"] || info["release_date"]))
    |> maybe_put(:tmdb_id, to_string_or_nil(info["tmdb_id"]))
    |> maybe_put(:imdb_id, info["kinopoisk_url"])
    |> maybe_put(:youtube_trailer, info["youtube_trailer"])
    |> maybe_put(:stream_icon, info["cover_big"] || info["movie_image"])
    |> maybe_put(:container_extension, movie_data["container_extension"])
  end

  defp parse_vod_info(_, _), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_decimal(nil), do: nil
  defp parse_decimal(""), do: nil

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, _} -> decimal
      :error -> nil
    end
  end

  defp parse_decimal(value) when is_number(value), do: Decimal.from_float(value / 1)
  defp parse_decimal(_), do: nil

  defp parse_integer(nil), do: nil
  defp parse_integer(""), do: nil

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_integer(value) when is_integer(value), do: value
  defp parse_integer(_), do: nil

  defp parse_duration_secs(nil), do: nil
  defp parse_duration_secs(value) when is_integer(value), do: value
  defp parse_duration_secs(value) when is_binary(value), do: parse_integer(value)
  defp parse_duration_secs(_), do: nil

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(""), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(value) when is_integer(value), do: Integer.to_string(value)
  defp to_string_or_nil(_), do: nil
end
