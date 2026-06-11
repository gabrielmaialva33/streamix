defmodule Streamix.Torrent.Sources.HtmlScraperTest do
  use ExUnit.Case, async: true

  alias Streamix.Torrent.Sources.HtmlScraper

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

  describe "fetch_listing/2 without config" do
    test "returns a disabled empty page when no base_url is set" do
      assert {:ok, [], %{disabled?: true}} =
               HtmlScraper.fetch_listing("comandotorrent", page: 1)
    end

    test "is safe for an unknown slug" do
      assert {:ok, [], %{disabled?: true}} =
               HtmlScraper.fetch_listing("totally-unknown-slug-xyz", page: 1)
    end
  end
end
