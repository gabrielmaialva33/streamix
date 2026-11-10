defmodule Streamix.Iptv.Tags.QueryParserTest do
  use ExUnit.Case, async: true

  alias Streamix.Iptv.Tags.QueryParser

  test "reads genre, decade and mood, leaving nothing over" do
    assert QueryParser.parse("Terror dos anos 80 leve") == %{
             genres: ["terror"],
             implied_genres: [],
             tags: %{eras: ["anos-1980"], moods: ["leve"]},
             decades: [1980],
             terms: ""
           }
  end

  test "decades in every common spelling" do
    for query <- ["anos 90", "década de 90", "decada 1990", "90s", "1990s"] do
      assert QueryParser.parse(query).decades == [1990], query
    end

    assert QueryParser.parse("anos 2000").tags.eras == ["anos-2000"]
    assert QueryParser.parse("anos 20").tags.eras == ["anos-1900-1920"]
    assert QueryParser.parse("anos 55").decades == []
  end

  test "matches the longest phrase and implies the subgenre's genre" do
    parsed = QueryParser.parse("comédia romântica de natal")
    assert parsed.tags.subgenres == ["comedia-romantica", "natal"]
    # "comédia romântica" names both shelves; Christmas implies Família.
    assert parsed.genres == ["comedia", "romance"]
    assert parsed.implied_genres == ["familia"]

    assert %{tags: %{subgenres: ["zumbi"]}, implied_genres: ["terror"]} =
             QueryParser.parse("zumbis")

    assert %{tags: %{subgenres: ["viagem-no-tempo"]}} = QueryParser.parse("viagem no tempo")
  end

  test "a named genre stays a genre even when it is also a tag" do
    parsed = QueryParser.parse("ficção científica no espaço")
    assert parsed.genres == ["ficcao-cientifica"]
    assert parsed.tags.settings == ["espaco"]

    assert %{genres: ["musica"], tags: %{themes: ["musica"]}} = QueryParser.parse("música")
  end

  test "synonyms for how people type, and the rest left for the semantic search" do
    assert QueryParser.parse("filme baseado em fatos reais").tags == %{
             origins: ["baseado-em-fatos"]
           }

    assert QueryParser.parse("animação pra crianças").tags == %{audience: ["infantil"]}
    assert QueryParser.parse("filmes do christopher nolan").terms == "christopher nolan"
    refute QueryParser.structured?(QueryParser.parse("filmes do christopher nolan"))
    assert QueryParser.structured?(QueryParser.parse("slasher"))
  end

  test "labels say what was understood, without restating a decade" do
    assert "terror anos 80 leve" |> QueryParser.parse() |> QueryParser.labels() ==
             ["Terror", "Anos 80", "Leve"]

    assert "slasher anos 2000" |> QueryParser.parse() |> QueryParser.labels() ==
             ["Anos 2000", "Slasher"]

    assert "filmes do nolan" |> QueryParser.parse() |> QueryParser.labels() == []
  end

  test "blank and non-text queries parse to nothing" do
    for query <- ["", "   ", nil, "de do da"] do
      parsed = QueryParser.parse(query)
      refute QueryParser.structured?(parsed)
      assert parsed.terms == ""
    end
  end
end
