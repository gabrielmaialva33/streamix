defmodule Streamix.Torrent.WantedTest do
  use ExUnit.Case, async: true

  alias Streamix.Torrent.Wanted

  describe "parse_csv/1" do
    test "parses tmdb_id,imdb_id,year,title rows with optional ids and years" do
      csv = """
      1003469,tt18559372,2022,Combinação do Azevinho
      1061251,,2022,Três Vidas e Um Sonho
      1043804,tt21955024,,Thank You, Next

      """

      assert {:ok,
              [
                %{
                  tmdb_id: "1003469",
                  imdb_id: "tt18559372",
                  year: 2022,
                  title: "Combinação do Azevinho"
                },
                %{tmdb_id: "1061251", imdb_id: nil, year: 2022, title: "Três Vidas e Um Sonho"},
                %{tmdb_id: "1043804", imdb_id: "tt21955024", year: nil, title: "Thank You, Next"}
              ]} = Wanted.parse_csv(csv)
    end

    test "accepts a row with only TMDB and IMDb ids (it will be unsearchable)" do
      assert {:ok, [%{tmdb_id: "1438050", imdb_id: "tt21990214", year: nil, title: nil}]} =
               Wanted.parse_csv("1438050,tt21990214,,\n")
    end

    test "skips a header line and duplicate TMDB ids" do
      csv = "tmdb_id,imdb_id,year,title\n603,tt0133093,1999,Matrix\n603,tt0133093,1999,Matrix\n"
      assert {:ok, [%{tmdb_id: "603"}]} = Wanted.parse_csv(csv)
    end

    test "reports the first invalid line" do
      assert {:error, {:invalid_line, 2, :invalid_imdb_id}} =
               Wanted.parse_csv("603,tt0133093,1999,Matrix\n604,nm123,1999,Other\n")

      assert {:error, {:invalid_line, 1, :expected_four_columns}} =
               Wanted.parse_csv("603,tt0133093\n")
    end
  end

  describe "new/1 and to_args/1" do
    test "round-trips through string-keyed job args" do
      {:ok, wanted} =
        Wanted.new(%{tmdb_id: 603, imdb_id: "TT0133093", year: "1999", title: " Matrix "})

      assert wanted == %{
               tmdb_id: "603",
               imdb_id: "tt0133093",
               year: 1999,
               title: "Matrix",
               original_title: nil
             }

      assert {:ok, ^wanted} = wanted |> Wanted.to_args() |> Wanted.new()
    end

    test "requires a TMDB id and a title" do
      assert {:error, :invalid_tmdb_id} = Wanted.new(%{title: "X"})
      assert {:error, :missing_title} = Wanted.new(%{tmdb_id: 1, title: "  "})

      assert {:error, {:invalid_wanted, 1, :invalid_year}} =
               Wanted.new_list([
                 %{tmdb_id: 1, title: "A"},
                 %{tmdb_id: 2, title: "B", year: "19x9"}
               ])
    end
  end
end
