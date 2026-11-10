defmodule Streamix.Iptv.Tags.VocabularyTest do
  use ExUnit.Case, async: true

  alias Streamix.Iptv.Genres.Vocabulary, as: Genres
  alias Streamix.Iptv.Tags.Vocabulary

  test "slugs are unique within each facet and every facet has entries" do
    for facet <- Vocabulary.facets() do
      slugs = Vocabulary.slugs(facet)
      assert length(slugs) == length(Enum.uniq(slugs)), "duplicate slug in #{facet}"
      assert Enum.all?(slugs, &Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, &1))
    end
  end

  test "every subgenre refines a canonical genre" do
    for slug <- Vocabulary.slugs(:subgenres) do
      assert Genres.slug?(Vocabulary.subgenre_genre(slug)), "#{slug} has no canonical genre"
    end
  end

  test "describe/0 carries every facet with its limit and entries" do
    described = Vocabulary.describe()
    assert Enum.map(described, & &1.facet) == Vocabulary.facets()
    assert %{limit: 1, single: true} = Enum.find(described, &(&1.facet == :pace))
    subgenres = Enum.find(described, &(&1.facet == :subgenres))
    assert {"slasher", "Slasher", "terror"} in subgenres.entries
  end

  test "sanitize keeps known slugs once, in order, up to the limit" do
    assert Vocabulary.sanitize(:moods, ["leve", "nope", "leve", "tenso", "sombrio", "epico"]) ==
             ["leve", "tenso", "sombrio"]

    assert Vocabulary.sanitize(:pace, "lento") == ["lento"]
    assert Vocabulary.sanitize(:pace, nil) == []
  end

  test "fix_eras turns a pre-2019 'atualidade' into the release decade" do
    assert Vocabulary.fix_eras(["atualidade"], 1999) == ["anos-1990"]
    assert Vocabulary.fix_eras(["anos-1980", "atualidade"], 1985) == ["anos-1980"]
    assert Vocabulary.fix_eras(["atualidade"], 1925) == ["anos-1900-1920"]
    assert Vocabulary.fix_eras(["atualidade"], 2023) == ["atualidade"]
    assert Vocabulary.fix_eras(["atualidade"], nil) == ["atualidade"]
    assert Vocabulary.fix_eras(["atualidade"], 1850) == []

    for year <- [1930, 1955, 2001, 2018],
        do:
          assert(
            Enum.all?(Vocabulary.fix_eras(["atualidade"], year), &Vocabulary.name(:eras, &1))
          )
  end
end
