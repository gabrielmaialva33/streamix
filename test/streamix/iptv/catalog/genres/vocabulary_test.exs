defmodule Streamix.Iptv.Genres.VocabularyTest do
  use ExUnit.Case, async: true

  alias Streamix.Iptv.Genres.Vocabulary

  @expected [
    %{slug: "acao", name: "Ação", position: 1},
    %{slug: "aventura", name: "Aventura", position: 2},
    %{slug: "animacao", name: "Animação", position: 3},
    %{slug: "comedia", name: "Comédia", position: 4},
    %{slug: "crime", name: "Crime", position: 5},
    %{slug: "documentario", name: "Documentário", position: 6},
    %{slug: "drama", name: "Drama", position: 7},
    %{slug: "familia", name: "Família", position: 8},
    %{slug: "fantasia", name: "Fantasia", position: 9},
    %{slug: "ficcao-cientifica", name: "Ficção científica", position: 10},
    %{slug: "guerra", name: "Guerra", position: 11},
    %{slug: "politica", name: "Política", position: 12},
    %{slug: "historia", name: "História", position: 13},
    %{slug: "terror", name: "Terror", position: 14},
    %{slug: "suspense", name: "Suspense", position: 15},
    %{slug: "misterio", name: "Mistério", position: 16},
    %{slug: "musica", name: "Música", position: 17},
    %{slug: "romance", name: "Romance", position: 18},
    %{slug: "faroeste", name: "Faroeste", position: 19},
    %{slug: "infantil", name: "Infantil", position: 20},
    %{slug: "novela", name: "Novela", position: 21},
    %{slug: "reality", name: "Reality", position: 22},
    %{slug: "talk-show", name: "Talk show", position: 23},
    %{slug: "noticias", name: "Notícias", position: 24}
  ]

  test "closed vocabulary preserves display order and exact Portuguese names" do
    assert Vocabulary.all() == @expected
    assert Vocabulary.slugs() == Enum.map(@expected, & &1.slug)

    for %{slug: slug, name: name} <- @expected do
      assert Vocabulary.slug?(slug)
      assert Vocabulary.name(slug) == name
    end

    for unknown <- [nil, :acao, "Ação", "unknown", 28, %{}] do
      refute Vocabulary.slug?(unknown)
      assert Vocabulary.name(unknown) == nil
    end
  end

  test "TMDB movie 28" do
    assert Vocabulary.from_tmdb(:movie, [28, "28"]) == ["acao"]
  end

  test "TMDB movie 12" do
    assert Vocabulary.from_tmdb(:movie, [12, "12"]) == ["aventura"]
  end

  test "TMDB movie 16" do
    assert Vocabulary.from_tmdb(:movie, [16, "16"]) == ["animacao"]
  end

  test "TMDB movie 35" do
    assert Vocabulary.from_tmdb(:movie, [35, "35"]) == ["comedia"]
  end

  test "TMDB movie 80" do
    assert Vocabulary.from_tmdb(:movie, [80, "80"]) == ["crime"]
  end

  test "TMDB movie 99" do
    assert Vocabulary.from_tmdb(:movie, [99, "99"]) == ["documentario"]
  end

  test "TMDB movie 18" do
    assert Vocabulary.from_tmdb(:movie, [18, "18"]) == ["drama"]
  end

  test "TMDB movie 10751" do
    assert Vocabulary.from_tmdb(:movie, [10_751, "10751"]) == ["familia"]
  end

  test "TMDB movie 14" do
    assert Vocabulary.from_tmdb(:movie, [14, "14"]) == ["fantasia"]
  end

  test "TMDB movie 878" do
    assert Vocabulary.from_tmdb(:movie, [878, "878"]) == ["ficcao-cientifica"]
  end

  test "TMDB movie 10752" do
    assert Vocabulary.from_tmdb(:movie, [10_752, "10752"]) == ["guerra"]
  end

  test "TMDB movie 36" do
    assert Vocabulary.from_tmdb(:movie, [36, "36"]) == ["historia"]
  end

  test "TMDB movie 27" do
    assert Vocabulary.from_tmdb(:movie, [27, "27"]) == ["terror"]
  end

  test "TMDB movie 53" do
    assert Vocabulary.from_tmdb(:movie, [53, "53"]) == ["suspense"]
  end

  test "TMDB movie 9648" do
    assert Vocabulary.from_tmdb(:movie, [9648, "9648"]) == ["misterio"]
  end

  test "TMDB movie 10402" do
    assert Vocabulary.from_tmdb(:movie, [10_402, "10402"]) == ["musica"]
  end

  test "TMDB movie 10749" do
    assert Vocabulary.from_tmdb(:movie, [10_749, "10749"]) == ["romance"]
  end

  test "TMDB movie 37" do
    assert Vocabulary.from_tmdb(:movie, [37, "37"]) == ["faroeste"]
  end

  test "TMDB tv 10759" do
    assert Vocabulary.from_tmdb(:tv, [10_759, "10759"]) == ["acao", "aventura"]
  end

  test "TMDB tv 16" do
    assert Vocabulary.from_tmdb(:tv, [16, "16"]) == ["animacao"]
  end

  test "TMDB tv 35" do
    assert Vocabulary.from_tmdb(:tv, [35, "35"]) == ["comedia"]
  end

  test "TMDB tv 80" do
    assert Vocabulary.from_tmdb(:tv, [80, "80"]) == ["crime"]
  end

  test "TMDB tv 99" do
    assert Vocabulary.from_tmdb(:tv, [99, "99"]) == ["documentario"]
  end

  test "TMDB tv 18" do
    assert Vocabulary.from_tmdb(:tv, [18, "18"]) == ["drama"]
  end

  test "TMDB tv 10751" do
    assert Vocabulary.from_tmdb(:tv, [10_751, "10751"]) == ["familia"]
  end

  test "TMDB tv 10765" do
    assert Vocabulary.from_tmdb(:tv, [10_765, "10765"]) == ["fantasia", "ficcao-cientifica"]
  end

  test "TMDB tv 10768" do
    assert Vocabulary.from_tmdb(:tv, [10_768, "10768"]) == ["guerra", "politica"]
  end

  test "TMDB tv 9648" do
    assert Vocabulary.from_tmdb(:tv, [9648, "9648"]) == ["misterio"]
  end

  test "TMDB tv 37" do
    assert Vocabulary.from_tmdb(:tv, [37, "37"]) == ["faroeste"]
  end

  test "TMDB tv 10762" do
    assert Vocabulary.from_tmdb(:tv, [10_762, "10762"]) == ["infantil"]
  end

  test "TMDB tv 10766" do
    assert Vocabulary.from_tmdb(:tv, [10_766, "10766"]) == ["novela"]
  end

  test "TMDB tv 10764" do
    assert Vocabulary.from_tmdb(:tv, [10_764, "10764"]) == ["reality"]
  end

  test "TMDB tv 10767" do
    assert Vocabulary.from_tmdb(:tv, [10_767, "10767"]) == ["talk-show"]
  end

  test "TMDB tv 10763" do
    assert Vocabulary.from_tmdb(:tv, [10_763, "10763"]) == ["noticias"]
  end

  test "TMDB expansion keeps first seen order and ignores formats and unknown ids" do
    assert Vocabulary.from_tmdb(:tv, [10_765, "10759", 18, 10_765, "10768"]) ==
             ~w(fantasia ficcao-cientifica acao aventura drama guerra politica)

    assert Vocabulary.from_tmdb(:movie, [18, "28", 18]) == ~w(drama acao)

    for kind <- [:movie, :tv] do
      assert Vocabulary.from_tmdb(kind, []) == []
      assert Vocabulary.from_tmdb(kind, [10_770, "10770", 0, "unknown", "28oops"]) == []
    end

    assert Vocabulary.from_tmdb(:movie, [10_759, 10_765, 10_768]) == []
    assert Vocabulary.from_tmdb(:tv, [28, 878, 10_752]) == []
  end
end
