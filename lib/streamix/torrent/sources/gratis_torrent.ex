defmodule Streamix.Torrent.Sources.GratisTorrent do
  @moduledoc """
  GratisTorrent BR source (dubbed / dual-audio movies).

  Tries, in order: the native HTML scraper (`:torrent_scrapers` config
  with a `base_url`), then a normalized JSON feed
  (`GRATISTORRENT_SOURCE_URL`), then disabled. Same shape as
  `Streamix.Torrent.Sources.ComandoTorrent`.
  """

  @behaviour Streamix.Torrent.Source

  alias Streamix.Torrent.Sources.{Helpers, HtmlScraper}

  @slug "gratistorrent"
  @name "GratisTorrent"
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
