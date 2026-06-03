defmodule Streamix.Gindex.ScraperTest do
  use ExUnit.Case, async: true

  alias Streamix.Gindex.Scraper

  # The previous test coverage here was zero because `season_folder?/1`
  # was a `defp`, so there was no way to pin the regex behaviour without
  # reaching into the module internals. Bringing it to the public API
  # catches PT-BR releases going forward.

  describe "season_folder?/1 — English release-scene layouts" do
    test "recognizes S01 / S10" do
      for name <- ["S01", "S10", "s01", "S99"] do
        assert Scraper.season_folder?(%{name: name}), "expected #{name} to match"
      end
    end

    test "recognizes `Season 1` variants" do
      for name <- ["Season 1", "Season 10", "season 02"] do
        assert Scraper.season_folder?(%{name: name})
      end
    end

    test "recognizes embedded release tags like `Show.S01.1080p`" do
      assert Scraper.season_folder?(%{name: "Show.S01.1080p.WEB-DL"})
    end
  end

  describe "season_folder?/1 — PT-BR variants (regression)" do
    # Real folder names from the AnimeZeY provider that the original
    # regex rejected.
    test "recognizes `Temporada NN`" do
      for name <- ["Temporada 1", "Temporada 01", "Temporada 10", "TEMPORADA 2"] do
        assert Scraper.season_folder?(%{name: name}), "expected #{name} to match"
      end
    end

    test "recognizes `Nª Temporada` with and without the ordinal marker" do
      for name <- ["1ª Temporada", "2ª Temporada", "10ª Temporada", "3 Temporada"] do
        assert Scraper.season_folder?(%{name: name})
      end
    end

    test "recognizes `T01` / `T1` shorthand" do
      for name <- ["T01", "T1", "T10", "t05"] do
        assert Scraper.season_folder?(%{name: name})
      end
    end

    test "recognizes `Volume NN` / `Vol. NN`" do
      for name <- ["Volume 1", "Vol 2", "Vol. 10"] do
        assert Scraper.season_folder?(%{name: name})
      end
    end

    test "tolerates trailing annotations like ` - Completa` or ` [Dublada]`" do
      # A strictly-anchored regex would miss these; loose matching is
      # deliberate so labels added by releasers don't drop the folder.
      assert Scraper.season_folder?(%{name: "Temporada 1 - Completa"})
      assert Scraper.season_folder?(%{name: "2ª Temporada [Dublada]"})
      assert Scraper.season_folder?(%{name: "T01 [1080p]"})
    end
  end

  describe "season_folder?/1 — rejects unrelated folders" do
    test "doesn't collapse single-episode folders or release metadata" do
      for name <- ["Episódio 01", "Bonus", "Extras", "Filme", "BluRay Bonus"] do
        refute Scraper.season_folder?(%{name: name}), "unexpected match: #{name}"
      end
    end
  end
end
