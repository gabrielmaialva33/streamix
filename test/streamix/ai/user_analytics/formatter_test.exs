defmodule Streamix.AI.UserAnalytics.FormatterTest do
  use ExUnit.Case, async: true

  alias Streamix.AI.UserAnalytics.Formatter

  test "maps vector results to the stable recommendation payload" do
    results = [
      %{
        id: "movie-42",
        score: 0.987_654,
        payload: %{
          "title" => "Arrival",
          "year" => 2016,
          "genres" => ["Ficção científica", "Drama"],
          "rating" => 8.1,
          "internal_only" => "not exposed"
        }
      }
    ]

    assert Formatter.recommendations(results) == [
             %{
               id: "movie-42",
               score: 0.988,
               title: "Arrival",
               year: 2016,
               genre: "Ficção científica, Drama",
               rating: 8.1
             }
           ]
  end

  test "keeps ordering and accepts an empty result set" do
    assert Formatter.recommendations([]) == []

    assert Enum.map(
             Formatter.recommendations([
               %{id: "first", score: 0.1, payload: %{}},
               %{id: "second", score: 0.2, payload: %{}}
             ]),
             & &1.id
           ) == ["first", "second"]
  end

  test "keeps compatibility with legacy singular genre payloads" do
    assert [recommendation] =
             Formatter.recommendations([
               %{id: 1, score: 0.5, payload: %{"genre" => "Ação"}}
             ])

    assert recommendation.genre == "Ação"
  end
end
