defmodule Streamix.Iptv.Content.SourceEquivalenceTest do
  use Streamix.DataCase, async: true

  import Streamix.IptvFixtures

  alias Streamix.Iptv.{CatalogItem, Movie}
  alias Streamix.Iptv.Content.SourceEquivalence

  test "prefers stable external IDs over title-based identity" do
    movie = %Movie{
      name: "The Example (2025) 4K",
      year: 2025,
      tmdb_id: " 12345 ",
      imdb_id: "tt999"
    }

    assert %{
             content_type: "movie",
             canonical_key: "tmdb:12345",
             method: "tmdb",
             confidence: 100
           } = SourceEquivalence.identity(movie)
  end

  test "links exact normalized title and year across providers" do
    first_provider = global_provider_fixture(%{name: "Source A"})
    second_provider = global_provider_fixture(%{name: "Source B"})

    first =
      movie_fixture(first_provider, %{
        name: "Arrival (2016) 4K",
        title: "Arrival",
        year: 2016,
        tmdb_id: nil,
        imdb_id: nil
      })

    second =
      movie_fixture(second_provider, %{
        name: "Arrival [Dublado]",
        title: "Arrival (2016)",
        year: 2016,
        tmdb_id: nil,
        imdb_id: nil
      })

    assert {:ok, 2} = SourceEquivalence.reconcile_contents([first, second])

    first_item = Repo.get!(CatalogItem, first.catalog_item_id)
    second_item = Repo.get!(CatalogItem, second.catalog_item_id)

    assert first_item.source_group_id == second_item.source_group_id
    assert first_item.source_match_method == "title_year"
    assert first_item.source_match_confidence == 92

    assert Enum.sort(SourceEquivalence.catalog_item_ids(first.catalog_item_id)) ==
             Enum.sort([first.catalog_item_id, second.catalog_item_id])
  end

  test "does not merge an exact title from different release years" do
    provider = global_provider_fixture()
    original = movie_fixture(provider, %{name: "Dune", title: "Dune", year: 1984})
    remake = movie_fixture(provider, %{name: "Dune", title: "Dune", year: 2021})

    assert {:ok, 2} = SourceEquivalence.reconcile_contents([original, remake])

    original_group = Repo.get!(CatalogItem, original.catalog_item_id).source_group_id
    remake_group = Repo.get!(CatalogItem, remake.catalog_item_id).source_group_id

    refute original_group == remake_group
  end

  test "manual verification links otherwise unsafe sources and is never overwritten automatically" do
    first_provider = global_provider_fixture(%{name: "Manual A"})
    second_provider = global_provider_fixture(%{name: "Manual B"})
    first = movie_fixture(first_provider, %{name: "Unknown source", year: nil})
    second = movie_fixture(second_provider, %{name: "Outra fonte", year: nil})

    assert {:ok, group} =
             SourceEquivalence.link_verified(
               [first.catalog_item_id, second.catalog_item_id],
               canonical_title: "Verified work"
             )

    first_item = Repo.get!(CatalogItem, first.catalog_item_id)
    assert first_item.source_group_id == group.id
    assert first_item.source_match_method == "manual"
    assert first_item.source_match_confidence == 100
    assert first_item.source_verified_at

    enriched_first = %{first | tmdb_id: "999"}
    assert {:ok, 0} = SourceEquivalence.reconcile_contents([enriched_first])

    preserved = Repo.get!(CatalogItem, first.catalog_item_id)
    assert preserved.source_group_id == group.id
    assert preserved.source_match_method == "manual"
  end

  test "rejects manual links with mixed content types" do
    provider = global_provider_fixture()
    movie = movie_fixture(provider)
    series = series_content_fixture(provider)

    assert {:error, :content_type_mismatch} =
             SourceEquivalence.link_verified([movie.catalog_item_id, series.catalog_item_id])
  end
end
