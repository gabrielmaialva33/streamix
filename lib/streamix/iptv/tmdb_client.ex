defmodule Streamix.Iptv.TmdbClient do
  @moduledoc """
  HTTP client facade for The Movie Database (TMDB) API.

  Supports multiple credential profiles so different ingestion sources can use
  their own TMDB API tokens and quotas. Profiles fall back to the default
  `:streamix, :tmdb` config when a key isn't overridden.

  Profiles:
    * `:default` - reads `config :streamix, :tmdb`
    * `:gindex` - reads `config :streamix, :tmdb_gindex`, merged over default

  All public fetch/search functions accept an optional `:profile` in their
  `opts`.

  All API calls are cached in Redis (L2) with in-memory L1 layer. The cache
  key is the resolved `tmdb_id` / query + params - profiles share cache since
  a given id returns the same payload regardless of which token fetched it.
  """

  alias Streamix.Cache
  alias Streamix.Iptv.TmdbClient.{Config, Parser, Search, Transport}

  @type profile :: :default | :gindex | atom()

  @doc """
  Checks if TMDB integration is enabled and configured for the given profile.
  """
  defdelegate enabled?(profile \\ :default), to: Config

  @doc """
  Fetches movie details from TMDB by movie ID.
  Returns `{:ok, movie_data}` or `{:error, reason}`.

  Results are cached in Redis for 24h.
  """
  def get_movie(tmdb_id, opts \\ []) when is_binary(tmdb_id) or is_integer(tmdb_id) do
    profile = Config.profile_from(opts)

    if Config.enabled?(profile) do
      Cache.fetch_tmdb_movie(tmdb_id, fn ->
        Transport.get_movie(tmdb_id, profile)
      end)
    else
      {:error, :tmdb_not_configured}
    end
  end

  @doc """
  Fetches TV series details from TMDB by series ID.
  Results are cached in Redis for 24h.
  """
  def get_series(tmdb_id, opts \\ []) when is_binary(tmdb_id) or is_integer(tmdb_id) do
    profile = Config.profile_from(opts)

    if Config.enabled?(profile) do
      Cache.fetch_tmdb_series(tmdb_id, fn ->
        Transport.get_series(tmdb_id, profile)
      end)
    else
      {:error, :tmdb_not_configured}
    end
  end

  @doc """
  Fetches a season with all episodes from TMDB.
  Results are cached in Redis for 24h.
  Returns episode details including overview, still_path, air_date, runtime.
  """
  def get_season(series_tmdb_id, season_number, opts \\ [])
      when (is_binary(series_tmdb_id) or is_integer(series_tmdb_id)) and is_integer(season_number) do
    profile = Config.profile_from(opts)

    if Config.enabled?(profile) do
      Cache.fetch_tmdb_season(series_tmdb_id, season_number, fn ->
        Transport.get_season(series_tmdb_id, season_number, profile)
      end)
    else
      {:error, :tmdb_not_configured}
    end
  end

  @doc """
  Searches for a movie by title and optionally year.
  Results are cached in Redis for 1h.
  """
  defdelegate search_movie(query, opts \\ []), to: Search

  @doc """
  Searches for a TV series by title and optionally year.
  Results are cached in Redis for 1h.
  Returns `{:ok, results}` or `{:error, reason}`.
  """
  defdelegate search_series(query, opts \\ []), to: Search

  @doc """
  Builds a full image URL from a TMDB image path.

  Sizes:
  - poster: w92, w154, w185, w342, w500, w780, original
  - backdrop: w300, w780, w1280, original
  """
  defdelegate image_url(path, size \\ "w500"), to: Transport

  @doc """
  Parses TMDB movie response into attributes suitable for our Movie schema.
  """
  defdelegate parse_movie_response(data), to: Parser

  @doc """
  Parses TMDB series response into attributes suitable for our Series schema.
  """
  defdelegate parse_series_response(data), to: Parser

  @doc """
  Parses TMDB season response and returns a map of episode_num => episode_attrs.
  This allows matching with our episodes by episode number.
  """
  defdelegate parse_season_episodes(data), to: Parser

  @doc """
  Parses a single TMDB episode into attributes suitable for our Episode schema.
  """
  defdelegate parse_episode_response(data), to: Parser
end
