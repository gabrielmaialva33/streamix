defmodule Streamix.Iptv.Torrent.Sources.ComandoTorrent do
  @moduledoc """
  ComandoTorrent-compatible BR source adapter.

  Configure `COMANDOTORRENT_SOURCE_URL` with a normalized JSON feed.
  The app keeps source parsing behind this adapter and shared helpers
  so the sync layer only sees stable `Source.listing_item/0` maps.
  """

  @behaviour Streamix.Iptv.Torrent.Source

  alias Streamix.Iptv.Torrent.Sources.Helpers

  @slug "comandotorrent"
  @name "ComandoTorrent"
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
