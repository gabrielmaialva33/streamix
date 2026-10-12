defmodule Streamix.Torrent.Sources.HtmlScraperTest do
  use ExUnit.Case, async: true

  alias Streamix.TestSupport.TorrentScraperStub, as: Stub
  alias Streamix.Torrent.Sources.{ComandoTorrent, GratisTorrent, HtmlScraper, ScraperSite}

  @comando "https://comando1.com"
  @comando_to "https://comandotorrents.to"
  @gratis "https://gratistorrent.com"

  # Posts linked from comando_listing.html
  @spider_man "#{@comando}/homem-aranha-um-novo-dia-torrent-2026-dual-audio-dublado-1080p/"
  @lanterns "#{@comando}/lanternas-1a-temporada-torrent-2026-dual-audio-5-1-web-dl-1080p/"
  @end_of_road "#{@comando}/o-fim-da-rua-torrent-2026-dual-audio-dublado-web-dl-1080p/"

  # Posts linked from gratis_listing.html
  @tadeo "#{@gratis}/as-aventuras-de-tadeo-e-a-lampada-magica-download-torrent/"
  @youth "#{@gratis}/youth-1a-temporada-download-torrent/"
  @revenge "#{@gratis}/codigo-vinganca-download-torrent/"
  @tehran "#{@gratis}/operacao-teerao-fan-dub-download-torrent/"
  @primetime "#{@gratis}/primetime-cam-legendado-download-torrent/"

  defp comando, do: %{ComandoTorrent.site() | enabled: true}
  defp gratis, do: %{GratisTorrent.site() | enabled: true}

  defp comando_listing_routes(base \\ @comando) do
    to_base = &String.replace(&1, @comando, base)

    %{
      to_base.("#{@comando}/") => to_base.(Stub.html("comando_listing.html")),
      to_base.(@spider_man) => to_base.(Stub.html("comando_post_sections.html")),
      to_base.(@end_of_road) => to_base.(Stub.html("comando_post_imdb.html"))
    }
  end

  describe "fetch_listing/2 — ComandoTorrent" do
    test "walks the posts of a listing page and skips seasons without fetching them" do
      Stub.route(comando_listing_routes())

      assert {:ok, items, meta} = HtmlScraper.fetch_listing(comando(), page: 1)

      assert meta.next_page == 2
      assert meta.mirror == @comando
      assert meta.skipped == 1
      assert meta.failed_posts == 0

      requested = Stub.requested_urls()
      assert requested == ["#{@comando}/", @spider_man, @end_of_road]
      refute @lanterns in requested

      assert [matrix, quadrant] = items
      assert matrix.external_id == @spider_man
      assert matrix.title == "Matrix: Resurrections"
      assert matrix.original_title == "The Matrix Resurrections"
      assert matrix.year == 2022
      assert quadrant.title == "Quadrant"
      assert quadrant.year == 2024
    end

    test "extracts the IMDb id from the post's info block" do
      Stub.route(comando_listing_routes())

      assert {:ok, [matrix, quadrant], _meta} = HtmlScraper.fetch_listing(comando(), page: 1)

      # The Matrix post links no IMDb page; the Quadrant post does.
      assert matrix.imdb_id == nil
      assert quadrant.imdb_id == "tt31179749"
    end

    test "resolves audio per magnet from its label and section heading" do
      Stub.route(comando_listing_routes())

      assert {:ok, [matrix, quadrant], _meta} = HtmlScraper.fetch_listing(comando(), page: 1)

      assert Enum.map(matrix.torrents, &{&1.audio_track, &1.quality}) == [
               {"dual", "1080p"},
               {"dual", "1080p"},
               {"dual", "2160p"},
               {"legendado", "2160p"},
               {"legendado", "2160p"}
             ]

      assert Enum.all?(matrix.torrents, &(&1.source_slug == "comandotorrent"))
      assert hd(matrix.torrents).size_bytes == 3_468_186_092
      assert hd(matrix.torrents).info_hash == "0a728e8ecce149b80fea9282fa40ea065ed07748"

      # The post title says "Dual Áudio" but its dubbed file is unofficial.
      assert [%{audio_track: "dublado_nao_oficial", release_flags: ["unofficial_dub"]}, legendado] =
               quadrant.torrents

      assert %{audio_track: "legendado", release_flags: []} = legendado
    end

    test "paginates with /page/N/ and stops at max_pages" do
      routes = comando_listing_routes()
      listing = Map.fetch!(routes, "#{@comando}/")
      Stub.route(Map.put(routes, "#{@comando}/page/2/", listing))

      assert {:ok, _items, %{next_page: nil}} =
               HtmlScraper.fetch_listing(%{comando() | max_pages: 2}, page: 2)

      assert hd(Stub.requested_urls()) == "#{@comando}/page/2/"
    end

    test "a 404 past the last page ends the listing instead of failing" do
      Stub.route(%{})

      assert {:ok, [], %{next_page: nil, end_of_listing?: true}} =
               HtmlScraper.fetch_listing(comando(), page: 3)
    end

    test "falls back to the next mirror when the primary serves a challenge" do
      routes =
        comando_listing_routes(@comando_to)
        |> Map.put("#{@comando}/", Stub.cloudflare_challenge())

      Stub.route(routes)

      assert {:ok, [matrix, _quadrant], meta} = HtmlScraper.fetch_listing(comando(), page: 1)
      assert meta.mirror == @comando_to
      assert hd(Stub.requested_urls()) == "#{@comando}/"

      # Identity stays on the canonical base, so a mirror switch does not
      # duplicate the movie.
      assert matrix.external_id == @spider_man
      assert matrix.source_url == String.replace(@spider_man, @comando, @comando_to)
    end

    test "keeps using the mirror that answered for the rest of the job" do
      routes =
        comando_listing_routes(@comando_to)
        |> Map.put("#{@comando}/", Stub.cloudflare_challenge())

      Stub.route(Map.put(routes, "#{@comando_to}/page/2/", routes["#{@comando_to}/"]))

      assert {:ok, _items, _meta} = HtmlScraper.fetch_listing(comando(), page: 1)
      _ = Stub.requested_urls()

      assert {:ok, _items, %{mirror: @comando_to}} = HtmlScraper.fetch_listing(comando(), page: 2)
      assert hd(Stub.requested_urls()) == "#{@comando_to}/page/2/"
    end

    test "reports blocked, with every attempt, when all mirrors are challenged" do
      Stub.route(%{
        "#{@comando}/" => Stub.cloudflare_challenge(),
        "#{@comando_to}/" => {403, "Forbidden"}
      })

      assert {:error, {:blocked, details}} = HtmlScraper.fetch_listing(comando(), page: 1)
      assert details.reason == :challenge

      assert details.attempts == [
               %{base_url: @comando, kind: :blocked, status: 403},
               %{base_url: @comando_to, kind: :blocked, status: 403}
             ]

      assert HtmlScraper.failure_kind({:blocked, details}) == :blocked
    end

    test "a page whose selector matches nothing is layout_changed, never an empty success" do
      gratis_markup = Stub.html("gratis_listing.html")
      Stub.route(%{"#{@comando}/" => gratis_markup, "#{@comando_to}/" => gratis_markup})

      assert {:error, {:layout_changed, details}} = HtmlScraper.fetch_listing(comando(), page: 1)
      assert details.what == :listing
      assert details.selector == "article h2.entry-title a"
      assert length(details.attempts) == 2
    end

    test "a page of posts that all lost their magnets is layout_changed" do
      no_magnets =
        "<html><body><article><h1 class='entry-title'>Filme (2024)</h1></article></body></html>"

      Stub.route(%{
        "#{@comando}/" => Stub.html("comando_listing.html"),
        @spider_man => no_magnets,
        @end_of_road => no_magnets
      })

      assert {:error, {:layout_changed, %{what: :magnets}}} =
               HtmlScraper.fetch_listing(comando(), page: 1)
    end

    test "stops the page at once when a post is rate limited" do
      Stub.route(%{
        "#{@comando}/" => Stub.html("comando_listing.html"),
        @spider_man => {429, [{"retry-after", "60"}], "slow down"}
      })

      assert {:error, {:rate_limited, %{post_url: @spider_man, retry_after_ms: 60_000}}} =
               HtmlScraper.fetch_listing(comando(), page: 1)

      refute @end_of_road in Stub.requested_urls()
    end
  end

  describe "fetch_listing/2 — GratisTorrent" do
    setup do
      routes = %{
        "#{@gratis}/" => Stub.html("gratis_listing.html"),
        @tadeo => Stub.html("gratis_post_base32.html"),
        @revenge => Stub.html("gratis_post_unofficial_dub.html"),
        @tehran => Stub.html("gratis_post_cam.html"),
        @primetime => {500, "boom"}
      }

      Stub.route(routes)
      {:ok, routes: routes}
    end

    test "finds posts with the new card selector and keeps going past a failed post" do
      assert {:ok, items, meta} = HtmlScraper.fetch_listing(gratis(), page: 1)

      assert length(items) == 3
      assert meta.skipped == 1
      assert meta.failed_posts == 1
      refute @youth in Stub.requested_urls()

      assert Enum.map(items, & &1.imdb_id) == ["tt36164852", "tt13149564", "tt21285562"]

      assert Enum.map(items, & &1.title) == [
               "As Aventuras de Tadeo e a Lâmpada Mágica",
               "Little Town",
               "Ponto Sem Retorno"
             ]
    end

    test "reads base32 magnets (newest GratisTorrent posts) as hex info hashes" do
      assert {:ok, [tadeo | _], _meta} = HtmlScraper.fetch_listing(gratis(), page: 1)

      assert [
               %{
                 info_hash: "4353ab0f949cfe6f4ef3deb2ee6ed04459ad068e",
                 magnet_uri: "magnet:?xt=urn:btih:4353ab0f949cfe6f4ef3deb2ee6ed04459ad068e&" <> _,
                 audio_track: "dual",
                 quality: "1080p"
               }
             ] = tadeo.torrents
    end

    test "flags unofficial dubs and camera captures per magnet" do
      assert {:ok, [_tadeo, little_town, cam], _meta} =
               HtmlScraper.fetch_listing(gratis(), page: 1)

      assert [
               %{audio_track: "dublado_nao_oficial", release_flags: ["unofficial_dub"]},
               %{audio_track: "legendado", release_flags: []}
             ] = little_town.torrents

      assert [%{audio_track: "legendado", release_flags: ["cam"]}] = cam.torrents
    end

    test "paginates with /pagina/N/", %{routes: routes} do
      Stub.route(Map.put(routes, "#{@gratis}/pagina/2/", Stub.html("gratis_listing.html")))

      assert {:ok, _items, %{next_page: 3}} = HtmlScraper.fetch_listing(gratis(), page: 2)
      assert hd(Stub.requested_urls()) == "#{@gratis}/pagina/2/"
    end

    test "falls back to brutotorrent.com with that mirror's own selectors" do
      bruto = "https://brutotorrent.com"
      bruto_post = "#{bruto}/da-magia-a-seducao-feitico-de-amor-torrent-dublado-download/"

      Stub.route(%{
        "#{@gratis}/" => Stub.cloudflare_challenge(),
        "#{bruto}/" => Stub.html("bruto_listing.html"),
        bruto_post => Stub.html("bruto_post.html")
      })

      assert {:ok, [item], %{mirror: ^bruto}} = HtmlScraper.fetch_listing(gratis(), page: 1)
      assert item.imdb_id == "tt10838180"
      assert item.title == "Matrix Resurrections"
      assert item.original_title == "The Matrix Resurrections"
      # A different slug layout: the served URL stays the identity.
      assert item.external_id == bruto_post
      assert length(item.torrents) == 5
    end
  end

  describe "fetch_listing/2 without config" do
    test "returns a disabled empty page when the site is switched off" do
      assert {:ok, [], %{disabled?: true}} = HtmlScraper.fetch_listing("comandotorrent", page: 1)
    end

    test "is safe for an unknown slug" do
      assert {:ok, [], %{disabled?: true}} =
               HtmlScraper.fetch_listing("totally-unknown-slug-xyz", page: 1)
    end
  end

  describe "search/3" do
    @matrix_search "#{@gratis}/index.php?busca=Matrix+Resurrections"

    test "uses index.php?busca= on GratisTorrent and only opens matching snippets" do
      Stub.route(%{
        @matrix_search => Stub.html("gratis_search.html"),
        "#{@gratis}/matrix-resurrections-download-torrent/" => Stub.html("gratis_post.html")
      })

      wanted = %{title: "Matrix Resurrections", year: 2021, imdb_id: "tt10838180"}
      assert {:ok, items, meta} = HtmlScraper.search(gratis(), wanted)

      requested = Stub.requested_urls()
      assert hd(requested) == @matrix_search
      refute Enum.any?(requested, &String.contains?(&1, "?s="))

      # Bundles ("todos os filmes"), other films and the tri-audio pack are
      # never opened.
      assert tl(requested) == [
               "#{@gratis}/matrix-resurrections-download-torrent/",
               "#{@gratis}/matrix-resurrections-legendado-download-torrent/"
             ]

      assert [%{imdb_id: "tt10838180"}] = items
      assert meta.candidates == 2
    end

    test "uses ?s= on ComandoTorrent" do
      url = "#{@comando}/?s=Matrix+Resurrections"
      Stub.route(%{url => Stub.html("comando_search.html")})

      assert {:ok, [], %{results: 3}} =
               HtmlScraper.search(comando(), %{title: "Matrix Resurrections", year: 2021})

      assert hd(Stub.requested_urls()) == url
    end

    test "an empty result page with the site's search box is a genuine miss" do
      empty =
        ~s(<html><body><form role="search"><input name="busca"></form><p>Nada encontrado</p></body></html>)

      Stub.route(%{"#{@gratis}/index.php?busca=Filme+Inexistente" => empty})

      assert {:ok, [], %{results: 0}} =
               HtmlScraper.search(gratis(), %{title: "Filme Inexistente", year: 2020})
    end

    test "a result page without posts or search box is layout_changed" do
      Stub.route(%{
        "#{@gratis}/index.php?busca=Filme" => "<html><body>novo layout</body></html>",
        "https://brutotorrent.com/index.php?busca=Filme" =>
          "<html><body>novo layout</body></html>",
        "https://apachetorrents.com/index.php?busca=Filme" =>
          "<html><body>novo layout</body></html>"
      })

      assert {:error, {:layout_changed, %{what: :search}}} =
               HtmlScraper.search(gratis(), %{title: "Filme", year: 2020})
    end

    test "titles without searchable text are not sent" do
      assert {:ok, [], %{unsearchable?: true}} =
               HtmlScraper.search(gratis(), %{title: "壹獄壹世界II：劫數難逃", year: 2023})

      assert Stub.requested_urls() == []
    end
  end

  describe "magnet_links/1" do
    test "extracts unique magnet URIs from a post document" do
      html = """
      <html><body>
        <div class="entry-content">
          <a href="magnet:?xt=urn:btih:aaaa1111&dn=Filme.1080p">1080p</a>
          <a href="magnet:?xt=urn:btih:bbbb2222&dn=Filme.720p">720p</a>
          <a href="magnet:?xt=urn:btih:aaaa1111&dn=Filme.1080p">1080p dup</a>
          <a href="https://example.tld/not-a-magnet">other</a>
        </div>
      </body></html>
      """

      {:ok, doc} = Floki.parse_document(html)
      magnets = HtmlScraper.magnet_links(doc)

      assert length(magnets) == 2
      assert "magnet:?xt=urn:btih:aaaa1111&dn=Filme.1080p" in magnets
      assert "magnet:?xt=urn:btih:bbbb2222&dn=Filme.720p" in magnets
    end

    test "returns empty list when there are no magnets" do
      {:ok, doc} = Floki.parse_document("<html><body><p>nada aqui</p></body></html>")
      assert HtmlScraper.magnet_links(doc) == []
    end
  end

  test "failure_kind/1 names scraper errors and nothing else" do
    assert HtmlScraper.failure_kind({:layout_changed, %{url: "x"}}) == :layout_changed
    assert HtmlScraper.failure_kind({:rate_limited, %{url: "x"}}) == :rate_limited
    assert HtmlScraper.failure_kind(:boom) == :error
    assert %ScraperSite{} = comando()
  end
end
