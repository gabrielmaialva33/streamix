defmodule StreamixWeb.Content.SourceBadgesTest do
  use ExUnit.Case, async: true

  alias StreamixWeb.Content.SourceBadges

  doctest SourceBadges

  test "puts the container first and keeps the marker order" do
    assert SourceBadges.badges(%{
             name: "Filme Dublado Legendado HDR 4K",
             title: nil,
             container_extension: "mp4"
           }) == ["MP4", "4K", "HDR", "LEG", "DUB"]
  end

  test "reads markers from both the raw name and the title, without duplicates" do
    assert SourceBadges.badges(%{
             name: "Filme 4k",
             title: "Filme 4K Legendado",
             container_extension: "mkv"
           }) == ["MKV", "4K", "LEG"]
  end

  test "a series flagged dub_available is dubbed even when its name says nothing" do
    assert SourceBadges.badges(%{name: "Dark 4K", title: "Dark", dub_available: true}) ==
             ["4K", "DUB"]

    assert SourceBadges.badges(%{name: "Dark Dublado", title: nil, dub_available: false}) ==
             ["DUB"]

    assert SourceBadges.badges(%{name: "Dark", title: "Dark", dub_available: false}) == []
  end

  test "ignores a missing or blank container and absent fields" do
    assert SourceBadges.badges(%{name: "Episode", title: "Episode", container_extension: ""}) ==
             []

    assert SourceBadges.badges(%{title: "Episódio Dublado"}) == ["DUB"]
  end
end
