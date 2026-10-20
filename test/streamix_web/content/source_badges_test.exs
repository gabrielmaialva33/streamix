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

  # Shapes seen in production catalogs; before, "[L]" copies were
  # indistinguishable from the dubbed copy of the same provider.
  test "reads bracketed and spelled-out audio markers" do
    assert SourceBadges.badges(%{name: "Uma Ideia de Você [L]", container_extension: "mp4"}) ==
             ["MP4", "LEG"]

    assert SourceBadges.badges(%{name: "1 Bordadeira [LEG]"}) == ["LEG"]
    assert SourceBadges.badges(%{name: "Filme [D]"}) == ["DUB"]
    assert SourceBadges.badges(%{name: "Filme [DUB]"}) == ["DUB"]
    assert SourceBadges.badges(%{name: "101 Dálmatas (1) 1961 Dublado 720p"}) == ["720p", "DUB"]
    assert SourceBadges.badges(%{name: "Filmes Legendados"}) == ["LEG"]
  end

  test "DUAL replaces the separate dubbed and subtitled badges" do
    assert SourceBadges.badges(%{
             name: "Uma Ideia de Você 2024 1080p WEB-DL DUAL",
             container_extension: "mkv"
           }) == ["MKV", "1080p", "DUAL"]

    assert SourceBadges.badges(%{name: "Filme Dublado Legendado Dual Áudio"}) == ["DUAL"]
  end

  test "shows only the highest resolution, and HDR variants" do
    assert SourceBadges.badges(%{name: "Filme 2160p 1080p"}) == ["4K"]
    assert SourceBadges.badges(%{name: "Filme UHD HDR10"}) == ["4K", "HDR"]
    assert SourceBadges.badges(%{name: "Filme 1080p"}) == ["1080p"]
  end

  test "matches whole words only" do
    assert SourceBadges.badges(%{name: "4Kids Dubladores Legendary"}) == []
    assert SourceBadges.badges(%{name: "Individual"}) == []
  end

  test "omits HLS delivery formats as containers" do
    assert SourceBadges.badges(%{name: "Filme Dublado", container_extension: "m3u8"}) == ["DUB"]
    assert SourceBadges.badges(%{name: "Filme", container_extension: "TXT"}) == []
  end

  test "ignores a missing or blank container and absent fields" do
    assert SourceBadges.badges(%{name: "Episode", title: "Episode", container_extension: ""}) ==
             []

    assert SourceBadges.badges(%{title: "Episódio Dublado"}) == ["DUB"]
  end

  # Production providers file subtitled copies under "▶️ Legendados" and
  # "FILMES | Legendados" without a marker in the name.
  test "reads audio markers from the shelves a copy sits on" do
    assert SourceBadges.badges(%{
             name: "Armadilha",
             container_extension: "mp4",
             categories: [%{name: "▶️ Legendados"}, %{name: "Suspense"}]
           }) == ["MP4", "LEG"]

    assert SourceBadges.badges(%{name: "Dark", categories: [%{name: "Séries | Dubladas"}]}) ==
             ["DUB"]

    # A shelf never adds a resolution, and unloaded categories are ignored.
    assert SourceBadges.badges(%{name: "Filme", categories: [%{name: "FILMES | 4K"}]}) == []

    assert SourceBadges.badges(%{name: "Filme", categories: %Ecto.Association.NotLoaded{}}) ==
             []
  end

  describe "distinct_copies/2" do
    defp copy(id, provider_id, fields \\ %{}),
      do:
        Map.merge(
          %{id: id, provider_id: provider_id, name: "Filme", container_extension: "mp4"},
          fields
        )

    test "one choice per provider and badge set, in order" do
      sources = [
        copy(1, :a),
        copy(2, :a),
        copy(3, :a, %{categories: [%{name: "FILMES | Legendados"}]}),
        copy(4, :b)
      ]

      assert Enum.map(SourceBadges.distinct_copies(sources), & &1.id) == [1, 3, 4]
    end

    test "the current copy stands for its group, in the group's place" do
      sources = [copy(1, :a), copy(4, :b), copy(2, :a)]

      assert Enum.map(SourceBadges.distinct_copies(sources, 2), & &1.id) == [2, 4]
    end

    test "failover candidates are compared by the row they wrap" do
      sources = [
        %{id: 1, provider_id: :a, content: copy(1, :a)},
        %{id: 2, provider_id: :a, content: copy(2, :a, %{container_extension: "mkv"})}
      ]

      assert Enum.map(SourceBadges.distinct_copies(sources), & &1.id) == [1, 2]
    end
  end
end
