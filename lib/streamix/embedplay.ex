defmodule Streamix.Embedplay do
  @moduledoc """
  Boundary for the optional Embedplay movie catalog and private HLS gateway.

  Upstream addresses and request headers stay inside this context. Clients
  receive only opaque resource identifiers authorized by StreamToken.
  """

  alias Streamix.Embedplay.{Gateway, Sessions}

  def enabled?, do: config(:enabled, false)

  def config(key, default \\ nil),
    do: Application.get_env(:streamix, :embedplay, [])[key] || default

  defdelegate import_movie(tmdb_id, imdb_id \\ nil), to: Streamix.Embedplay.Catalog
  defdelegate sync_catalog(), to: Streamix.Embedplay.Catalog, as: :sync
  defdelegate enqueue_sync(), to: Streamix.Embedplay.Catalog

  defdelegate open_movie(movie), to: Sessions, as: :open
  defdelegate fetch_resource(session_id, resource_id, movie_id, opts \\ []), to: Gateway
  defdelegate rewrite_playlist(body, base_url, session_id, movie_id, resource_url), to: Gateway
  defdelegate invalidate_session(session_id), to: Sessions, as: :invalidate
end
