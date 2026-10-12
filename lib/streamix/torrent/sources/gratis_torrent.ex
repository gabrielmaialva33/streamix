defmodule Streamix.Torrent.Sources.GratisTorrent do
  @moduledoc """
  GratisTorrent BR source (dubbed / dual-audio movies).

  gratistorrent.com is no longer WordPress: listing cards are
  `div.col a.text-decoration-none`, pagination is `/pagina/N/` (30 posts per
  page) and search is `index.php?busca=` (`?s=` is ignored). Every detail
  page names the film's IMDb id, and each magnet button states its own
  audio ("DUAL ÁUDIO", "LEGENDADO", "DUBLAGEM NÃO OFICIAL").

  The same catalog is published by sister sites with their own themes.
  `brutotorrent.com` and `apachetorrents.com` are configured as fallback
  mirrors with profiles verified against their markup; their post URLs use
  different slugs, so a movie scraped through them keeps the mirror URL as
  its identity. Sister sites whose layout could not be verified, and
  `hdrtorrents` (which stamps "Dublado/Dual Áudio" on every title and would
  mislead `ReleaseInfo`), are deliberately not in the list.

  Falls back to a normalized JSON feed (`GRATISTORRENT_SOURCE_URL`) only
  when the scraper is switched off.
  """

  @behaviour Streamix.Torrent.Source

  alias Streamix.Torrent.Sources.{Helpers, HtmlScraper, ScraperSite}

  @slug "gratistorrent"
  @name "GratisTorrent"
  @rate_limit_ms 1_500

  @defaults [
    base_urls: [
      "https://gratistorrent.com",
      "https://brutotorrent.com",
      "https://apachetorrents.com"
    ],
    list_path: "/",
    page_path: "/pagina/{page}/",
    search_path: "/index.php?busca={query}",
    post_link_selector: "div.col a.text-decoration-none",
    content_selector: "section.download-section",
    title_selector: "h1.movie-title",
    original_title_selector: "p.original-title",
    imdb_selector: "a[aria-label='IMDb'], a[href*='imdb.com/title/']",
    poster_selector: "#posterCarousel img",
    page_marker_selector: "input[name='busca']",
    max_posts_per_page: 30,
    max_pages: 5,
    mirror_profiles: %{
      "brutotorrent.com" => [
        post_link_selector: "article.media-card h2.media-card-title a",
        content_selector: "div.download-panel",
        title_selector: "h1.item-title",
        original_title_selector: "p.item-subtitle",
        imdb_selector: "a.item-pill.imdb, a[href*='imdb.com/title/']",
        poster_selector: "div.item-cover img",
        same_paths: false
      ],
      "apachetorrents.com" => [
        post_link_selector: "div.capa-item h2.capa-titulo a",
        content_selector: "div.download-block",
        title_selector: "h1.item-h1",
        original_title_selector: nil,
        imdb_selector: "div.infos a[href*='imdb.com']",
        poster_selector: "img.item-poster",
        same_paths: false
      ]
    }
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
