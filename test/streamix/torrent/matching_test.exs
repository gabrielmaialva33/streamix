defmodule Streamix.Torrent.MatchingTest do
  use ExUnit.Case, async: true

  alias Streamix.Torrent.Matching

  describe "match/2" do
    test "matches on equal IMDb ids even when the titles differ" do
      wanted = %{title: "Combinação do Azevinho", year: 2022, imdb_id: "tt18559372"}
      release = %{title: "Combinação ao Azevinho", year: 2022, imdb_id: "tt18559372"}

      assert {:match, :imdb} = Matching.match(wanted, release)
    end

    test "a different IMDb id is a hard no, whatever the title says" do
      wanted = %{title: "O Legionário", year: 2021, imdb_id: "tt8318284"}
      release = %{title: "O Legionário", year: 2022, imdb_id: "tt13767266"}

      assert :no_match = Matching.match(wanted, release)
    end

    test "falls back to title + year within one year" do
      wanted = %{title: "Matrix Resurrections", year: 2021, imdb_id: "tt10838180"}

      assert {:match, :title_year} =
               Matching.match(wanted, %{title: "Matrix Resurrections", year: 2022, imdb_id: nil})

      assert :no_match =
               Matching.match(wanted, %{title: "Matrix Resurrections", year: 2023, imdb_id: nil})
    end

    test "compares titles without accents, punctuation or leading article" do
      wanted = %{title: "Trauma Therapy: Psychosis", year: 2023}

      assert {:match, :title_year} =
               Matching.match(wanted, %{title: "Trauma Therapy - Psychosis", year: 2023})

      assert {:match, :title_year} =
               Matching.match(%{title: "O Túmulo Vazio", year: 1945}, %{
                 title: "Tumulo Vazio",
                 year: 1945
               })
    end

    test "uses the release's original title too" do
      wanted = %{title: "The Matrix Resurrections", year: 2021}

      assert {:match, :title_year} =
               Matching.match(wanted, %{
                 title: "Matrix: Resurrections",
                 original_title: "The Matrix Resurrections",
                 year: 2022
               })
    end

    test "never matches by title when a year is unknown" do
      assert :no_match =
               Matching.match(%{title: "Anjo Negro", year: nil}, %{
                 title: "Anjo Negro",
                 year: 2024
               })

      assert :no_match =
               Matching.match(%{title: "Anjo Negro", year: 2024}, %{
                 title: "Anjo Negro",
                 year: nil
               })
    end

    test "ignores malformed IMDb ids" do
      wanted = %{title: "Quadrant", year: 2024, imdb_id: "31179749"}
      release = %{title: "Quadrant", year: 2024, imdb_id: "tt31179749"}

      assert {:match, :title_year} = Matching.match(wanted, release)
    end
  end

  describe "prefilter/2" do
    test "accepts a snippet carrying the title words and a close year" do
      wanted = %{title: "Combinação do Azevinho", year: 2022}

      assert Matching.prefilter(
               wanted,
               "/combinacao-ao-azevinho-torrent-2022-dual-audio/ Combinação ao Azevinho Torrent (2022)"
             )
    end

    test "rejects snippets for other titles or far-off years" do
      wanted = %{title: "Matrix Resurrections", year: 2021}

      refute Matching.prefilter(wanted, "/matrix-reloaded-download-torrent/ Matrix Reloaded 2003")

      refute Matching.prefilter(
               wanted,
               "/matrix-resurrections-download/ Matrix Resurrections 2015"
             )

      assert Matching.prefilter(
               wanted,
               "/matrix-resurrections-download-torrent/ Matrix Resurrections"
             )
    end
  end

  describe "search_query/1 and searchable?/1" do
    test "drops punctuation and keeps at most six words" do
      assert Matching.search_query("Homem-Aranha: Um Novo Dia") == "Homem Aranha Um Novo Dia"

      assert Matching.search_query("Mistérios da Antiguidade com Albert Lin: O Dilúvio") ==
               "Mistérios da Antiguidade com Albert Lin"
    end

    test "titles without Latin letters or digits are not searchable" do
      refute Matching.searchable?("壹獄壹世界II：劫數難逃")
      assert Matching.searchable?("It")
      assert Matching.searchable?("Barata")
      refute Matching.searchable?(nil)
    end
  end
end
