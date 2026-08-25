defmodule Streamix.Search do
  alias Streamix.Iptv.TmdbClient

  @moduledoc """
  Application boundary for catalog search and public search discovery.

  Search-facing delivery code should use this module instead of depending on
  the broad IPTV facade. Query execution remains in the specialized catalog
  modules while this module owns the stable application API.
  """

  alias Streamix.Iptv.{Channels, Movies, SeriesOps}

  defdelegate search_channels(user_id, query, opts \\ []), to: Channels, as: :search
  defdelegate search_movies(user_id, query, opts \\ []), to: Movies, as: :search

  defdelegate search_public_channels(query, opts \\ []),
    to: Channels,
    as: :search_public

  defdelegate search_public_movies(query, opts \\ []), to: Movies, as: :search_public

  defdelegate search_public_series(query, opts \\ []),
    to: SeriesOps,
    as: :search_public

  defdelegate search_series(user_id, query, opts \\ []), to: SeriesOps, as: :search

  # Search document and TMDB matching support

  defdelegate list_search_documents(kind, ids, opts),
    to: Streamix.Iptv.SearchDocuments,
    as: :list

  def search_tmdb(:movie, query, opts),
    do: TmdbClient.search_movie(query, opts)

  def search_tmdb(:series, query, opts),
    do: TmdbClient.search_series(query, opts)
end
