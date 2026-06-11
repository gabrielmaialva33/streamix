defmodule Streamix.Torrent.Sources.ComandoTorrent do
  @moduledoc """
  ComandoTorrent BR source (dubbed / dual-audio movies).

  Tries, in order: the native HTML scraper (`:torrent_scrapers` config
  with a `base_url`), then a normalized JSON feed
  (`COMANDOTORRENT_SOURCE_URL`), then disabled. The scraper path is
  preferred for BR sites with no API; the feed path stays available for
  a future external crawler.
  """

  @behaviour Streamix.Torrent.Source

  alias Streamix.Torrent.Sources.{Helpers, HtmlScraper}

  @slug "comandotorrent"
  @name "ComandoTorrent"
  @rate_limit_ms 1_500

  @impl true
  def slug, do: @slug

  @impl true
  def name, do: @name

  @impl true
  def rate_limit_ms, do: @rate_limit_ms

  @impl true
  def fetch_listing(opts \\ []) do
    case HtmlScraper.fetch_listing(@slug, opts) do
      {:ok, [], %{disabled?: true}} -> fetch_feed(opts)
      result -> result
    end
  end

  defp fetch_feed(opts) do
    case Helpers.fetch_normalized_feed(@slug, opts) do
      {:error, :not_configured} -> {:ok, [], %{next_page: nil, disabled?: true}}
      result -> result
    end
  end
end
