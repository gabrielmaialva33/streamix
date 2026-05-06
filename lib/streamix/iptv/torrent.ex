defmodule Streamix.Iptv.Torrent do
  @moduledoc """
  Public API for torrent ingestion + playback.

  Mirrors `Streamix.Iptv.Gindex` in shape: this module is the single
  entrypoint outside the `Streamix.Iptv.Torrent.*` namespace, so the
  worker layer and any future LiveViews/controllers don't reach into
  internal sync modules directly.
  """

  alias Streamix.Iptv.Torrent.{Sources, Sync}

  defdelegate sync_provider(provider), to: Sync
  defdelegate sync_source(provider, source_module), to: Sync

  @doc """
  Lists the configured torrent sources.
  """
  defdelegate sources(), to: Sources, as: :list

  @doc """
  Looks up a source module by its slug, or returns `nil`.
  """
  defdelegate source_for(slug), to: Sources, as: :fetch
end
