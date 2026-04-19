defmodule Streamix.Iptv.RankedSearchTest do
  # Hits the repo — the fuzzy / unaccent / similarity branches all need
  # the real Postgres extensions, so no mocks here.
  use Streamix.DataCase, async: true

  import Streamix.IptvFixtures

  alias Streamix.Iptv

  setup do
    # `search_public` scopes to providers marked global/public, which is
    # exactly what `global_provider_fixture/0` produces.
    {:ok, provider: global_provider_fixture()}
  end

  describe "search_public_movies/2 ranking" do
    test "exact match ranks above prefix ranks above substring", %{provider: provider} do
      # These three titles all contain "matrix" but at different
      # positions — the ranked search has to surface the exact title
      # first, then the prefix match, then the substring match.
      movie_fixture(provider, %{name: "Matrix Resurrections", stream_id: 1001})
      movie_fixture(provider, %{name: "Matrix", stream_id: 1002})
      movie_fixture(provider, %{name: "Enter the Matrix", stream_id: 1003})

      [first, second, third] = Iptv.search_public_movies("Matrix", limit: 10)

      assert first.name == "Matrix"
      assert second.name == "Matrix Resurrections"
      assert third.name == "Enter the Matrix"
    end

    test "unaccent folds diacritics on both sides", %{provider: provider} do
      # `pokemon` with no accent still has to match `Pokémon`.
      movie_fixture(provider, %{name: "Pokémon: The First Movie", stream_id: 1004})

      results = Iptv.search_public_movies("pokemon", limit: 5)
      assert Enum.any?(results, &(&1.name == "Pokémon: The First Movie"))
    end

    test "trigram catches common typos", %{provider: provider} do
      # Regression for the TV remote UX: `Matris` (typo) must still
      # find `Matrix`.
      movie_fixture(provider, %{name: "The Matrix", stream_id: 1005})

      results = Iptv.search_public_movies("Matris", limit: 5)
      assert Enum.any?(results, &(&1.name == "The Matrix"))
    end

    test "populates :rank_score on every row", %{provider: provider} do
      movie_fixture(provider, %{name: "Matrix", stream_id: 1006})

      [match] = Iptv.search_public_movies("Matrix", limit: 1)
      assert is_integer(match.rank_score)
      # Exact-match branch is 1000 in the CASE expression.
      assert match.rank_score >= 1000
    end

    test "queries far below threshold return no results", %{provider: provider} do
      # `qzqzqz` has no trigram overlap with anything in the fixture
      # set; the min_score filter has to keep the payload empty
      # instead of returning every row with rank_score=0.
      movie_fixture(provider, %{name: "The Godfather", stream_id: 1007})

      assert Iptv.search_public_movies("qzqzqz", limit: 10) == []
    end
  end

  describe "normalize_query/1" do
    test "lowercases, trims and strips diacritics" do
      alias Streamix.Iptv.RankedSearch
      assert RankedSearch.normalize_query("  Pokémon  ") == "pokemon"
      assert RankedSearch.normalize_query("Mátrïx") == "matrix"
    end
  end
end
