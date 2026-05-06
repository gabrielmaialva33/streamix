defmodule Streamix.Iptv.TmdbClient.Search do
  @moduledoc false

  alias Streamix.Cache
  alias Streamix.Iptv.TmdbClient.{Config, Transport}

  def search_movie(query, opts \\ []) do
    search(:movie, query, opts)
  end

  def search_series(query, opts \\ []) do
    search(:series, query, opts)
  end

  defp search(type, query, opts) do
    profile = Config.profile_from(opts)

    if Config.enabled?(profile) do
      fetch_search(type, query, opts, fn ->
        Transport.search(type, query, opts[:year], profile)
      end)
    else
      {:error, :tmdb_not_configured}
    end
  end

  defp fetch_search(:movie, query, opts, fun), do: Cache.fetch_tmdb_search_movie(query, opts, fun)

  defp fetch_search(:series, query, opts, fun),
    do: Cache.fetch_tmdb_search_series(query, opts, fun)
end
