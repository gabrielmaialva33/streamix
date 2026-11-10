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

  test "collapses provider copies of one title into the best-scored one" do
    results = [
      %{id: 1, score: 0.9, payload: %{"variant_key" => "tmdb:550"}},
      %{id: 2, score: 0.8, payload: %{"variant_key" => "tmdb:550"}},
      %{id: 3, score: 0.7, payload: %{"variant_key" => "tmdb:13"}},
      %{id: 4, score: 0.6, payload: %{}},
      %{id: 5, score: 0.5, payload: %{}}
    ]

    assert Enum.map(Formatter.recommendations(results), & &1.id) == [1, 3, 4, 5]
  end
end
