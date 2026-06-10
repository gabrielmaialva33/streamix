defmodule Streamix.Torrent do
  @moduledoc """
  Public API for torrent ingestion + playback.

  Mirrors `Streamix.Gindex` in shape: this module is the single
  entrypoint outside the `Streamix.Torrent.*` namespace, so the
  worker layer and any future LiveViews/controllers don't reach into
  internal sync modules directly.
  """

  alias Streamix.Torrent.{Catalog, Sources, Sync}

  defdelegate sync_provider(provider), to: Sync
  defdelegate sync_source(provider, source_module), to: Sync
  defdelegate refresh_provider_counts(provider), to: Sync

  # Catalog read model (powers the dedicated torrent screen).
  defdelegate provider(), to: Catalog
  defdelegate list_movies(opts \\ []), to: Catalog
  defdelegate count_movies(), to: Catalog
  defdelegate streams_for_movie(movie_id), to: Catalog
  defdelegate best_stream_for_movie(movie_id), to: Catalog

  @doc """
  Lists the configured torrent sources.
  """
  defdelegate sources(), to: Sources, as: :list

  @doc """
  Looks up a source module by its slug, or returns `nil`.
  """
  defdelegate source_for(slug), to: Sources, as: :fetch
end
