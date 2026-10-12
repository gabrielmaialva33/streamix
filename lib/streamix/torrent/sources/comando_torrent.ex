defmodule Streamix.Torrent.Sources.ComandoTorrent do
  @moduledoc """
  ComandoTorrent BR source (dubbed / dual-audio movies).

  A WordPress site (theme "Frontier"): 20 posts per listing page under
  `/page/N/`, `?s=` search, one post per release with plain `magnet:`
  links grouped under `:: DUAL ÁUDIO ::` / `:: LEGENDADO ::` headings and
  an IMDb link in the info block of most posts.

  The historical domain `comando.la` now answers with a Cloudflare managed
  challenge, which we do not solve. The same site is served normally by
  the mirrors below, tried in order (`COMANDOTORRENT_BASE_URLS` replaces
  the list; the legacy `COMANDOTORRENT_BASE_URL` is tried first).

  Falls back to a normalized JSON feed (`COMANDOTORRENT_SOURCE_URL`) only
  when the scraper is switched off.
  """

  @behaviour Streamix.Torrent.Source

  alias Streamix.Torrent.Sources.{Helpers, HtmlScraper, ScraperSite}

  @slug "comandotorrent"
  @name "ComandoTorrent"
  @rate_limit_ms 1_500

  @defaults [
    base_urls: ["https://comando1.com", "https://comandotorrents.to"],
    list_path: "/",
    page_path: "/page/{page}/",
    search_path: "/?s={query}",
    post_link_selector: "article h2.entry-title a",
    content_selector: "article div.entry-content",
    title_selector: "article h1.entry-title",
    imdb_selector: "article div.entry-content a[href*='imdb.com']",
    poster_selector: "article div.entry-content img",
    page_marker_selector: "input[name='s']",
    max_posts_per_page: 20,
    max_pages: 5
  ]

  @impl true
  def slug, do: @slug

  @impl true
  def name, do: @name

  @impl true
  def rate_limit_ms, do: @rate_limit_ms

  @doc "The resolved scraper site (defaults merged with runtime config)."
  @spec site() :: ScraperSite.t()
  def site, do: ScraperSite.build(@slug, @defaults)

  @impl true
  def fetch_listing(opts \\ []) do
    case HtmlScraper.fetch_listing(site(), opts) do
      {:ok, [], %{disabled?: true}} -> fetch_feed(opts)
      result -> result
    end
  end

  @impl true
  def search(wanted, opts \\ []), do: HtmlScraper.search(site(), wanted, opts)

  defp fetch_feed(opts) do
    case Helpers.fetch_normalized_feed(@slug, opts) do
      {:error, :not_configured} -> {:ok, [], %{next_page: nil, disabled?: true}}
      result -> result
    end
  end
end
