defmodule Streamix.Torrent.Sources do
  @moduledoc """
  Registry of enabled torrent sources.

  Each source implements the `Streamix.Torrent.Source` behaviour
  and is iterated by `Streamix.Torrent.Sync.sync_provider/1` to
  populate the `movies` and `torrent_streams` tables.

  The default list includes the built-in adapters. Sources that need a
  deployment-specific scraper/feed return an empty page until their
  endpoint is configured. Production deployments can still override it
  via:

      config :streamix, :torrent_sources, [
        Streamix.Torrent.Sources.Yts,
        Streamix.Torrent.Sources.GratisTorrent
      ]
  """

  alias Streamix.Torrent.Sources.{ComandoTorrent, Eztv, GratisTorrent, Yts}

  @default_sources [Yts, Eztv, GratisTorrent, ComandoTorrent]

  @doc """
  Returns the list of enabled torrent source modules.

  Order is meaningful — the orchestrator processes sources sequentially
  and the first source that provides a given info_hash "wins" the
  `source_slug` field in `torrent_streams`.
  """
  @spec list() :: [module()]
  def list do
    Application.get_env(:streamix, :torrent_sources, @default_sources)
  end

  @doc """
  Looks up a source module by its slug. Returns `nil` when the slug
  is unknown — the orchestrator surfaces this as `{:error,
  :unknown_source}` rather than crashing the worker.
  """
  @spec fetch(String.t()) :: module() | nil
  def fetch(slug) when is_binary(slug) do
    Enum.find(list(), fn module -> module.slug() == slug end)
  end
end
