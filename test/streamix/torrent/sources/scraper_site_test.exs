defmodule Streamix.Torrent.Sources.ScraperSiteTest do
  use ExUnit.Case, async: false

  alias Streamix.Torrent.Sources.{ComandoTorrent, GratisTorrent, ScraperSite}

  setup do
    previous = Application.get_env(:streamix, :torrent_scrapers)
    on_exit(fn -> Application.put_env(:streamix, :torrent_scrapers, previous) end)
    :ok
  end

  describe "build/2" do
    test "ComandoTorrent defaults to working mirrors, not the challenged comando.la" do
      Application.put_env(:streamix, :torrent_scrapers, [])
      site = ComandoTorrent.site()

      assert site.enabled

      assert Enum.map(site.mirrors, & &1.base_url) == [
               "https://comando1.com",
               "https://comandotorrents.to"
             ]

      refute Enum.any?(site.mirrors, &(&1.host == "comando.la"))
      assert site.canonical_base == "https://comando1.com"
      assert site.min_interval_ms == 0
    end

    test "GratisTorrent uses its own pagination, search and per-mirror profiles" do
      Application.put_env(:streamix, :torrent_scrapers, [])
      site = GratisTorrent.site()
      [gratis, bruto, apache] = site.mirrors

      assert ScraperSite.listing_url(gratis, 2) == "https://gratistorrent.com/pagina/2/"

      assert ScraperSite.search_url(gratis, "matrix resurrections") ==
               "https://gratistorrent.com/index.php?busca=matrix+resurrections"

      assert gratis.post_link_selector == "div.col a.text-decoration-none"
      assert bruto.post_link_selector == "article.media-card h2.media-card-title a"
      assert apache.post_link_selector == "div.capa-item h2.capa-titulo a"
      refute bruto.same_paths
    end

    test "a legacy single base URL is tried first, before the default mirrors" do
      Application.put_env(:streamix, :torrent_scrapers,
        comandotorrent: [base_url: "https://comando.la/"]
      )

      assert Enum.map(ComandoTorrent.site().mirrors, & &1.base_url) ==
               ["https://comando.la", "https://comando1.com", "https://comandotorrents.to"]
    end

    test "an explicit mirror list replaces the defaults; nil overrides are ignored" do
      Application.put_env(:streamix, :torrent_scrapers,
        comandotorrent: [
          base_urls: ["https://comandotorrents.to", "not a url"],
          post_link_selector: nil,
          max_pages: 12
        ]
      )

      site = ComandoTorrent.site()

      assert [
               %{
                 base_url: "https://comandotorrents.to",
                 post_link_selector: "article h2.entry-title a"
               }
             ] =
               site.mirrors

      assert site.max_pages == 12
    end

    test "enabled: false switches the scraper off" do
      Application.put_env(:streamix, :torrent_scrapers, gratistorrent: [enabled: false])
      refute ScraperSite.enabled?(GratisTorrent.site())
    end

    test "a slug without mirrors is disabled" do
      refute ScraperSite.enabled?(ScraperSite.build("unconfigured-slug-xyz", []))
    end
  end

  describe "canonical_url/2" do
    test "re-keys same-layout mirror URLs onto the canonical base" do
      Application.put_env(:streamix, :torrent_scrapers, [])
      site = ComandoTorrent.site()

      assert ScraperSite.canonical_url(site, "https://comandotorrents.to/quadrant-torrent-2024/") ==
               "https://comando1.com/quadrant-torrent-2024/"
    end

    test "keeps the served URL for a mirror with its own slugs" do
      Application.put_env(:streamix, :torrent_scrapers, [])
      site = GratisTorrent.site()
      url = "https://brutotorrent.com/matrix-resurrections-torrent-dublado-download/"

      assert ScraperSite.canonical_url(site, url) == url
    end
  end
end
