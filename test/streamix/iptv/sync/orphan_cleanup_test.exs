defmodule Streamix.Iptv.Sync.OrphanCleanupTest do
  use Streamix.DataCase, async: true

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv.{CatalogItem, Category, Movie, Series}
  alias Streamix.Iptv.Sync.OrphanCleanup
  alias Streamix.Repo

  test "deletes missing content and its catalog/category rows inside one provider scope" do
    provider = provider_fixture(user_fixture())
    other_provider = provider_fixture(user_fixture())
    kept = movie_fixture(provider, %{stream_id: 8_001})
    removed = movie_fixture(provider, %{stream_id: 8_002})
    other = movie_fixture(other_provider, %{stream_id: 8_002})
    category = category_fixture(provider, "vod")

    Repo.insert_all("item_categories", [
      %{catalog_item_id: kept.catalog_item_id, category_id: category.id},
      %{catalog_item_id: removed.catalog_item_id, category_id: category.id}
    ])

    assert OrphanCleanup.delete(provider.id, [kept.stream_id],
             schema: Movie,
             stream_id_field: :stream_id
           ) == 1

    assert Repo.get(Movie, kept.id)
    refute Repo.get(Movie, removed.id)
    assert Repo.get(Movie, other.id)
    refute Repo.get(CatalogItem, removed.catalog_item_id)

    assert Repo.aggregate(
             from(
               assoc in "item_categories",
               where: assoc.catalog_item_id == ^removed.catalog_item_id
             ),
             :count
           ) == 0
  end

  test "supports series ids and treats an empty upstream list as delete all" do
    provider = provider_fixture(user_fixture())
    first = series_content_fixture(provider, %{series_id: 9_001})
    second = series_content_fixture(provider, %{series_id: 9_002})

    assert OrphanCleanup.delete(provider.id, [],
             schema: Series,
             stream_id_field: :series_id
           ) == 2

    refute Repo.get(Series, first.id)
    refute Repo.get(Series, second.id)
    refute Repo.get(CatalogItem, first.catalog_item_id)
    refute Repo.get(CatalogItem, second.catalog_item_id)
  end

  defp category_fixture(provider, type) do
    %Category{}
    |> Category.changeset(%{
      provider_id: provider.id,
      external_id: "category-#{System.unique_integer([:positive])}",
      name: "Cleanup Category",
      type: type
    })
    |> Repo.insert!()
  end
end
