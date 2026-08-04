defmodule Streamix.Cache.Keys do
  @moduledoc """
  Canonical cache key builders. Kept in one place so invalidation
  patterns (`*:user:<id>`, `*:provider:<id>`, `epg:*:<provider>:*`)
  always match what we write.
  """

  @spec categories(integer()) :: String.t()
  def categories(user_id), do: "categories:user:#{user_id}"

  @spec provider_categories(integer()) :: String.t()
  def provider_categories(provider_id), do: "categories:provider:#{provider_id}"

  @spec channel_count(integer()) :: String.t()
  def channel_count(provider_id), do: "channel_count:provider:#{provider_id}"

  @spec groups(integer()) :: String.t()
  def groups(user_id), do: "groups:user:#{user_id}"

  @spec user_profile(integer()) :: String.t()
  def user_profile(user_id), do: "ai:user:#{user_id}:profile"

  @spec user_insights(integer()) :: String.t()
  def user_insights(user_id), do: "ai:user:#{user_id}:insights"

  @spec recommendations(integer(), String.t(), integer(), boolean()) :: String.t()
  def recommendations(user_id, type, limit, exclude_watched) do
    "ai:user:#{user_id}:recommendations:#{type}:#{limit}:exclude:#{exclude_watched}"
  end

  @spec public_stats() :: String.t()
  def public_stats, do: "stats:public"

  @spec featured() :: String.t()
  def featured, do: "featured:#{Date.utc_today()}"

  @spec epg_now(integer(), String.t()) :: String.t()
  def epg_now(provider_id, epg_channel_id), do: "epg:now:#{provider_id}:#{epg_channel_id}"

  @spec epg_current(integer(), String.t()) :: String.t()
  def epg_current(provider_id, epg_channel_id),
    do: "epg:current:#{provider_id}:#{epg_channel_id}"

  @spec tmdb_movie(integer() | String.t()) :: String.t()
  def tmdb_movie(tmdb_id), do: "tmdb:movie:#{tmdb_id}"

  @spec tmdb_series(integer() | String.t()) :: String.t()
  def tmdb_series(tmdb_id), do: "tmdb:series:#{tmdb_id}"

  @spec tmdb_season(integer() | String.t(), integer()) :: String.t()
  def tmdb_season(series_id, season_num), do: "tmdb:season:#{series_id}:#{season_num}"

  @spec tmdb_search_movie(String.t(), Keyword.t()) :: String.t()
  def tmdb_search_movie(query, opts) do
    hash = :erlang.phash2({query, opts[:year]})
    "tmdb:search:movie:#{hash}"
  end

  @spec tmdb_search_series(String.t(), Keyword.t()) :: String.t()
  def tmdb_search_series(query, opts) do
    hash = :erlang.phash2({query, opts[:year]})
    "tmdb:search:series:#{hash}"
  end
end
