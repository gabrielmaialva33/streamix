defmodule Streamix.Iptv.Sync.CleanupTest do
  use Streamix.DataCase, async: false

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Ecto.Adapters.SQL
  alias Streamix.Iptv.{CatalogItem, Episode, Season}
  alias Streamix.Iptv.Sync.Cleanup
  alias Streamix.Repo
  alias Streamix.WatchParty.Room

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

  test "checks only the content table declared by each catalog item", %{provider: provider} do
    channel = channel_fixture(provider)
    movie = movie_fixture(provider)
    series = series_content_fixture(provider)

    season =
      %Season{}
      |> Season.changeset(%{season_number: 1, series_id: series.id})
      |> Repo.insert!()

    episode_item = catalog_item_fixture("episode", provider.id)

    episode =
      %Episode{}
      |> Episode.changeset(%{
        episode_id: 1,
        episode_num: 1,
        season_id: season.id,
        catalog_item_id: episode_item.id
      })
      |> Repo.insert!()

    orphan_ids =
      for content_type <- ~w(live_channel movie series episode) do
        catalog_item_fixture(content_type, provider.id).id
      end

    assert {:ok, %{catalog_items: 4}} = Cleanup.cleanup_orphaned_user_data(provider.id)

    assert Repo.get(CatalogItem, channel.catalog_item_id)
    assert Repo.get(CatalogItem, movie.catalog_item_id)
    assert Repo.get(CatalogItem, series.catalog_item_id)
    assert Repo.get(CatalogItem, episode.catalog_item_id)
    refute Repo.exists?(from item in CatalogItem, where: item.id in ^orphan_ids)
  end

  test "removes watch-party rooms through the WatchParty boundary", %{provider: provider} do
    orphan = catalog_item_fixture("movie", provider.id)

    room =
      %Room{}
      |> Room.create_changeset(%{
        host_user_id: provider.user_id,
        catalog_item_id: orphan.id,
        source_type: "movie",
        source_id: orphan.id
      })
      |> Repo.insert!()

    assert {:ok, %{catalog_items: 1, watch_party_rooms: 1}} =
             Cleanup.cleanup_orphaned_user_data(provider.id)

    refute Repo.get(Room, room.id)
  end

  test "aggregates cleanup counts across transactional chunks", %{provider: provider} do
    now = DateTime.utc_now(:second)

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

  test "returns the exact same orphan IDs as the legacy CASE query across content types, providers, limits, and keyset cursors",
       %{
         provider: provider,
         other_provider: other_provider
       } do
    p1_live_orphan_1 = catalog_item_fixture("live_channel", provider.id)
    _p1_channel = channel_fixture(provider)
    p2_movie_orphan = catalog_item_fixture("movie", other_provider.id)
    p1_movie_orphan_1 = catalog_item_fixture("movie", provider.id)
    _p1_movie = movie_fixture(provider)
    p1_series_orphan_1 = catalog_item_fixture("series", provider.id)
    p1_series = series_content_fixture(provider)
    _p2_series = series_content_fixture(other_provider)

    season =
      %Season{}
      |> Season.changeset(%{season_number: 1, series_id: p1_series.id})
      |> Repo.insert!()

    linked_episode_item = catalog_item_fixture("episode", provider.id)

    %Episode{}
    |> Episode.changeset(%{
      episode_id: 101,
      episode_num: 1,
      season_id: season.id,
      catalog_item_id: linked_episode_item.id
    })
    |> Repo.insert!()

    p1_episode_orphan_1 = catalog_item_fixture("episode", provider.id)
    p2_episode_orphan = catalog_item_fixture("episode", other_provider.id)
    p1_live_orphan_2 = catalog_item_fixture("live_channel", provider.id)
    p1_movie_orphan_2 = catalog_item_fixture("movie", provider.id)
    p1_series_orphan_2 = catalog_item_fixture("series", provider.id)
    p1_episode_orphan_2 = catalog_item_fixture("episode", provider.id)
    p2_live_orphan = catalog_item_fixture("live_channel", other_provider.id)
    p2_series_orphan = catalog_item_fixture("series", other_provider.id)

    expected_p1_orphans = [
      p1_live_orphan_1.id,
      p1_movie_orphan_1.id,
      p1_series_orphan_1.id,
      p1_episode_orphan_1.id,
      p1_live_orphan_2.id,
      p1_movie_orphan_2.id,
      p1_series_orphan_2.id,
      p1_episode_orphan_2.id
    ]

    expected_p2_orphans = [
      p2_movie_orphan.id,
      p2_episode_orphan.id,
      p2_live_orphan.id,
      p2_series_orphan.id
    ]

    assert Cleanup.find_orphaned_catalog_item_ids(provider.id) == expected_p1_orphans
    assert Cleanup.find_orphaned_catalog_item_ids(other_provider.id) == expected_p2_orphans

    for scope <- [provider.id, other_provider.id, nil],
        limit <- [nil, 1, 2, 3, 4, 5, 7, 10, 20] do
      assert Cleanup.find_orphaned_catalog_item_ids(scope, limit: limit) ==
               legacy_find_orphaned_catalog_item_ids(scope, limit: limit)
    end

    # Keyset pagination (id > after_id) without OFFSET produces the exact same sequence
    paged_p1 = page_orphan_ids(provider.id, 3)
    assert paged_p1 == expected_p1_orphans
    assert paged_p1 == legacy_find_orphaned_catalog_item_ids(provider.id, [])

    paged_all = page_orphan_ids(nil, 3)
    assert paged_all == legacy_find_orphaned_catalog_item_ids(nil, [])
  end

  test "honors :after_id keyset cursor in cleanup_orphaned_user_data/2", %{provider: provider} do
    o1 = catalog_item_fixture("live_channel", provider.id)
    o2 = catalog_item_fixture("movie", provider.id)
    o3 = catalog_item_fixture("series", provider.id)
    o4 = catalog_item_fixture("episode", provider.id)

    assert {:ok, %{catalog_items: 2}} =
             Cleanup.cleanup_orphaned_user_data(provider.id, after_id: o1.id, limit: 2)

    remaining_ids =
      CatalogItem
      |> where([ci], ci.provider_id == ^provider.id)
      |> order_by([ci], asc: ci.id)
      |> select([ci], ci.id)
      |> Repo.all()

    assert remaining_ids == [o1.id, o4.id]
    refute Repo.get(CatalogItem, o2.id)
    refute Repo.get(CatalogItem, o3.id)
  end

  test "plans orphan lookup using Anti Joins without SubPlans", %{provider: provider} do
    for scope <- [provider.id, nil] do
      query = Cleanup.orphaned_catalog_item_ids_query(scope, limit: 500)
      {sql, params} = SQL.to_sql(:all, Repo, query)
      plan = explain_query(sql, params)

      assert plan =~ "Anti Join"
      refute plan =~ "SubPlan"
    end
  end

  defp page_orphan_ids(provider_id, page_size, after_id \\ nil, acc \\ []) do
    batch =
      Cleanup.find_orphaned_catalog_item_ids(provider_id,
        limit: page_size,
        after_id: after_id
      )

    case batch do
      [] ->
        acc

      ids ->
        last_id = List.last(ids)
        page_orphan_ids(provider_id, page_size, last_id, acc ++ ids)
    end
  end

  defp explain_query(sql, params) do
    Repo.query!("EXPLAIN " <> sql, params).rows
    |> Enum.map_join("\n", fn [line] -> line end)
  end

  defp legacy_find_orphaned_catalog_item_ids(provider_id, opts) do
    limit = Keyword.get(opts, :limit)
    after_id = Keyword.get(opts, :after_id)

    CatalogItem
    |> where(
      [ci],
      fragment(
        """
        CASE ?
          WHEN 'live_channel' THEN
            NOT EXISTS (SELECT 1 FROM live_channels lc WHERE lc.catalog_item_id = ?)
          WHEN 'movie' THEN
            NOT EXISTS (SELECT 1 FROM movies m WHERE m.catalog_item_id = ?)
          WHEN 'series' THEN
            NOT EXISTS (SELECT 1 FROM series s WHERE s.catalog_item_id = ?)
          WHEN 'episode' THEN
            NOT EXISTS (SELECT 1 FROM episodes e WHERE e.catalog_item_id = ?)
          ELSE TRUE
        END
        """,
        ci.content_type,
        ci.id,
        ci.id,
        ci.id,
        ci.id
      )
    )
    |> then(fn q ->
      if provider_id, do: where(q, [ci], ci.provider_id == ^provider_id), else: q
    end)
    |> then(fn q ->
      if after_id, do: where(q, [ci], ci.id > ^after_id), else: q
    end)
    |> order_by([ci], asc: ci.id)
    |> then(fn q ->
      if limit, do: limit(q, ^limit), else: q
    end)
    |> select([ci], ci.id)
    |> Repo.all()
  end
end
