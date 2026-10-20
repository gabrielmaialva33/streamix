defmodule StreamixWeb.Content.TitleIdentityTest do
  use ExUnit.Case, async: true

  alias StreamixWeb.Content.TitleIdentity

  defp row(id, fields), do: Map.merge(%{id: id, name: nil, title: nil, year: nil}, fields)

  test "keeps one card per title, first copy wins" do
    rows = [
      row(1, %{name: "Farol da Ilusão", tmdb_id: "10"}),
      row(2, %{name: "Farol da Ilusão [L]"}),
      row(3, %{name: "Sociedade das Sombras 4K", tmdb_id: "20"}),
      row(4, %{name: "The Shadow Society", tmdb_id: "20"}),
      row(5, %{name: "Outro Filme", imdb_id: "tt1"}),
      row(6, %{name: "Another Film", imdb_id: "tt1"})
    ]

    assert Enum.map(TitleIdentity.distinct(rows), & &1.id) == [1, 3, 5]
  end

  test "a remake from another year is a different title" do
    rows = [
      row(1, %{name: "Halloween", year: 1978}),
      row(2, %{name: "Halloween (2018)", year: 2018}),
      row(3, %{name: "Halloween [LEG]", year: 1978}),
      row(4, %{name: "Halloween"})
    ]

    assert Enum.map(TitleIdentity.distinct(rows), & &1.id) == [1, 2]
  end

  test "drops the excluded title and its copies" do
    current = row(1, %{name: "Armadilha", tmdb_id: "30", year: 2024})

    rows = [
      row(1, %{name: "Armadilha", tmdb_id: "30"}),
      row(2, %{name: "Armadilha [LEG]", year: 2024}),
      row(3, %{name: "Trap", tmdb_id: "30"}),
      row(4, %{name: "Fragmentado"})
    ]

    assert Enum.map(TitleIdentity.distinct(rows, [current]), & &1.id) == [4]
  end

  test "blank ids and names never merge unrelated rows" do
    rows = [
      row(1, %{name: "Um", tmdb_id: ""}),
      row(2, %{name: "Dois", tmdb_id: " "}),
      row(3, %{name: nil, tmdb_id: nil}),
      row(4, %{name: nil, tmdb_id: nil})
    ]

    assert Enum.map(TitleIdentity.distinct(rows), & &1.id) == [1, 2, 3, 4]
  end
end
