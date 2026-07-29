defmodule Streamix.Iptv.Sync.CleanupTest do
  use Streamix.DataCase, async: false

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv.CatalogItem
  alias Streamix.Iptv.Sync.Cleanup
  alias Streamix.Repo

  setup do
    user = user_fixture()

    %{
      provider: provider_fixture(user),
      other_provider: provider_fixture(user)
    }
  end

  test "only removes orphaned catalog items from the selected provider", %{
    provider: provider,
    other_provider: other_provider
  } do
    orphan = catalog_item_fixture("movie", provider.id)
    other_orphan = catalog_item_fixture("movie", other_provider.id)

    assert {:ok,
            %{
              favorites: 0,
              watch_history: 0,
              watch_party_rooms: 0,
              catalog_items: 1
            }} = Cleanup.cleanup_orphaned_user_data(provider.id)

    refute Repo.get(CatalogItem, orphan.id)
    assert Repo.get(CatalogItem, other_orphan.id)
  end

  test "honors the cleanup limit", %{provider: provider} do
    orphans =
      for _ <- 1..3 do
        catalog_item_fixture("movie", provider.id)
      end

    assert {:ok, %{catalog_items: 2}} =
             Cleanup.cleanup_orphaned_user_data(provider.id, limit: 2)

    remaining_ids =
      CatalogItem
      |> where([ci], ci.provider_id == ^provider.id)
      |> select([ci], ci.id)
      |> Repo.all()

    assert length(remaining_ids) == 1
    assert remaining_ids -- Enum.map(orphans, & &1.id) == []
  end

  test "aggregates cleanup counts across transactional chunks", %{provider: provider} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      for _ <- 1..501 do
        %{
          content_type: "movie",
          provider_id: provider.id,
          inserted_at: now,
          updated_at: now
        }
      end

    {501, nil} = Repo.insert_all(CatalogItem, rows)

    assert {:ok, %{catalog_items: 501}} =
             Cleanup.cleanup_orphaned_user_data(provider.id)

    refute Repo.exists?(from ci in CatalogItem, where: ci.provider_id == ^provider.id)
  end
end
