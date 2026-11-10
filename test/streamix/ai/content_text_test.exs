defmodule Streamix.AI.ContentTextTest do
  use ExUnit.Case, async: true

  alias Streamix.AI.ContentText

  test "labels every facet on its own line, in a stable order" do
    text =
      ContentText.build(%{
        title: "Interestelar",
        year: 2014,
        genres: "Aventura, Drama, Ficção científica",
        keywords: ["time travel", "space travel", " "],
        directors: ["Christopher Nolan"],
        writers: ["Jonathan Nolan", "Christopher Nolan"],
        cast: ~w(A B C D E F G),
        tagline: "  ",
        plot: "Uma equipe viaja por um buraco de minhoca."
      })

    assert text ==
             """
             Interestelar (2014)
             Gêneros: Aventura, Drama, Ficção científica
             Palavras-chave: time travel, space travel
             Direção: Christopher Nolan
             Roteiro: Jonathan Nolan, Christopher Nolan
             Elenco: A, B, C, D, E
             Uma equipe viaja por um buraco de minhoca.\
             """
  end

  test "writes classified tags as labelled lines after the genres" do
    text =
      ContentText.build(%{
        title: "Pânico",
        year: 1996,
        genres: "Terror",
        tag_labels: %{
          subgenres: ["Slasher", "Quem matou? (whodunit)"],
          moods: ["Tenso"],
          pace: ["Acelerado"],
          eras: ["Anos 90"],
          settings: [],
          audience: ["Adulto"],
          themes: ["Assassinato"],
          origins: []
        },
        plot: "Um assassino mascarado."
      })

    assert text ==
             """
             Pânico (1996)
             Gêneros: Terror
             Subgêneros: Slasher, Quem matou? (whodunit)
             Clima: Tenso
             Ritmo: Acelerado
             Época: Anos 90
             Público: Adulto
             Temas: Assassinato
             Um assassino mascarado.\
             """
  end

  test "a bare title is just the title" do
    assert ContentText.build(%{title: "Sem Dados", genres: nil, cast: []}) == "Sem Dados"
  end
end
