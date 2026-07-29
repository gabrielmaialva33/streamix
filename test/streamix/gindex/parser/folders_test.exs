defmodule Streamix.Gindex.Parser.FoldersTest do
  use ExUnit.Case, async: true

  alias Streamix.Gindex.Parser.Folders

  describe "parse_movie_folder/1" do
    test "parses localized, original and simple year folder shapes" do
      assert Folders.parse_movie_folder("  Cidade de Deus [City of God] (2002)  ") == %{
               name: "Cidade de Deus",
               original_name: "City of God",
               year: 2002
             }

      assert Folders.parse_movie_folder("Central do Brasil (1998)") == %{
               name: "Central do Brasil",
               original_name: nil,
               year: 1998
             }
    end

    test "keeps an unstructured name and handles nil" do
      assert Folders.parse_movie_folder("Sem Metadados") == %{
               name: "Sem Metadados",
               original_name: nil,
               year: nil
             }

      assert Folders.parse_movie_folder(nil) == %{name: nil, original_name: nil, year: nil}
    end

    test "uses the same contract for series folders" do
      assert Folders.parse_series_folder("Dark [Dark] (2017)") == %{
               name: "Dark",
               original_name: "Dark",
               year: 2017
             }
    end
  end

  describe "parse_anime_folder/1" do
    test "extracts original names, years and release types" do
      assert Folders.parse_anime_folder("Cowboy Bebop [Kaubōi Bibappu]") == %{
               name: "Cowboy Bebop",
               original_name: "Kaubōi Bibappu",
               year: nil,
               type: nil,
               season_indicator: nil
             }

      assert Folders.parse_anime_folder("Steins;Gate (2011)") == %{
               name: "Steins;Gate",
               original_name: nil,
               year: 2011,
               type: nil,
               season_indicator: nil
             }

      assert Folders.parse_anime_folder("FLCL (ova)") == %{
               name: "FLCL",
               original_name: nil,
               year: nil,
               type: "OVA",
               season_indicator: nil
             }
    end

    test "extracts common anime season indicators" do
      assert Folders.parse_anime_folder("Naruto 2").season_indicator == "2"

      assert Folders.parse_anime_folder("Jujutsu Kaisen 2nd Season").season_indicator ==
               "2nd Season"

      assert Folders.parse_anime_folder("Bleach Season 3").season_indicator == "Season 3"
      assert Folders.parse_anime_folder("Attack on Titan Part 4").season_indicator == "Part 4"
    end

    test "keeps a plain name and handles nil" do
      assert Folders.parse_anime_folder("Monster") == %{
               name: "Monster",
               original_name: nil,
               year: nil,
               type: nil,
               season_indicator: nil
             }

      assert Folders.parse_anime_folder(nil) == %{
               name: nil,
               original_name: nil,
               year: nil,
               type: nil,
               season_indicator: nil
             }
    end
  end

  describe "parse_season_folder/1" do
    test "supports canonical and scene season markers" do
      assert Folders.parse_season_folder("S02") == %{season_number: 2}
      assert Folders.parse_season_folder("Season 12") == %{season_number: 12}
      assert Folders.parse_season_folder("Show.S03.1080p") == %{season_number: 3}
      assert Folders.parse_season_folder("Show S4 WEB-DL") == %{season_number: 4}
    end

    test "defaults to season one when no marker exists" do
      assert Folders.parse_season_folder("Specials") == %{season_number: 1}
      assert Folders.parse_season_folder(nil) == %{season_number: 1}
    end
  end
end
