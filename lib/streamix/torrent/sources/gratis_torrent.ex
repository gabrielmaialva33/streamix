defmodule Streamix.Torrent.Sources.GratisTorrent do
  @moduledoc """
  GratisTorrent-compatible BR source adapter.

  Configure `GRATISTORRENT_SOURCE_URL` with a normalized JSON feed.
  Source-specific crawlers should emit that stable payload and reuse
  `Streamix.Torrent.Sources.Helpers` for magnet and release
  normalization.
  """

  @behaviour Streamix.Torrent.Source

  alias Streamix.Torrent.Sources.Helpers

  @slug "gratistorrent"
  @name "GratisTorrent"
  @rate_limit_ms 1_000

  @impl true
  def slug, do: @slug

  @impl true
  def name, do: @name

  @impl true
  def rate_limit_ms, do: @rate_limit_ms

  @impl true
  def fetch_listing(opts \\ []) do
    case Helpers.fetch_normalized_feed(@slug, opts) do
      {:error, :not_configured} -> {:ok, [], %{next_page: nil, disabled?: true}}
      result -> result
    end
  end
end
