defmodule StreamixWeb.StationPathsTest do
  use ExUnit.Case, async: true

  alias StreamixWeb.StationPaths

  test "episodes read as series, number and their own name" do
    assert StationPaths.label(%{
             "title" => "Chaves (1973)",
             "subtitle" => "T4:E2 · Temporada 04 Episodio 02 (A limpeza do pátio)"
           }) == "Chaves · T4:E2 · A limpeza do pátio"

    assert StationPaths.label(%{
             "title" => "Friends [L]",
             "subtitle" => "T5:E23 · Friends [L] (1994) S05 E23"
           }) ==
             "Friends · T5:E23"

    assert StationPaths.label(%{"title" => "Scooby", "subtitle" => "T1:E1"}) == "Scooby · T1:E1"
  end

  test "films read as title and a known year" do
    assert StationPaths.label(%{"title" => "Pânico [LEG]", "year" => 1996}) == "Pânico (1996)"
    assert StationPaths.label(%{"title" => "Sem Ano", "year" => 0}) == "Sem Ano"
    assert StationPaths.label(nil) == ""
  end

  test "the watch path follows the item's type, old programs included" do
    assert StationPaths.watch("chaves", %{
             item: %{"type" => "episode", "content_id" => 7},
             offset: 30
           }) ==
             "/watch/episode/7?station=chaves&t=30"

    assert StationPaths.watch("terror", %{item: %{"movie_id" => 11}, offset: 0}) ==
             "/watch/movie/11?station=terror&t=0"
  end
end
