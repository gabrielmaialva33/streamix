defmodule Streamix.Iptv.Sync.ContentUpsertTest do
  use Streamix.DataCase, async: true

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv.{CatalogItem, Movie, Series}
  alias Streamix.Iptv.Sync.ContentUpsert
  alias Streamix.Repo

  test "rolls back the whole batch when category association rebuilding fails" do
    provider = provider_fixture(user_fixture())
    now = ~U[2026-07-30 15:00:00Z]
    streams = [%{"stream_id" => 7_001, "name" => "Atomic Movie"}]

    attrs_fn = fn stream, provider_id, timestamp ->
      %{
        stream_id: stream["stream_id"],
        name: stream["name"],
        provider_id: provider_id,
        inserted_at: timestamp,
        updated_at: timestamp
      }
    end

    category_fn = fn _batch, _returned, _lookup ->
      raise "category rebuild failed"
    end

    assert_raise RuntimeError, "category rebuild failed", fn ->
      ContentUpsert.upsert_batched(streams, provider.id, %{}, now,
        schema: Movie,
        stream_id_field: :stream_id,
        attrs_fn: attrs_fn,
        category_fn: category_fn,
        content_type: "movie"
      )
    end

    assert Repo.aggregate(from(movie in Movie, where: movie.provider_id == ^provider.id), :count) ==
             0

    assert Repo.aggregate(
             from(item in CatalogItem, where: item.provider_id == ^provider.id),
             :count
           ) == 0
  end

  test "returns deduplicated stream ids in provider order" do
    provider = provider_fixture(user_fixture())
    now = ~U[2026-07-30 15:00:00Z]

    streams = [
      %{"stream_id" => 7_001, "name" => "First"},
      %{"stream_id" => 7_002, "name" => "Second"},
      %{"stream_id" => 7_001, "name" => "Duplicate"},
      %{"stream_id" => 7_003, "name" => "Third"}
    ]

    attrs_fn = fn stream, provider_id, timestamp ->
      %{
        stream_id: stream["stream_id"],
        name: stream["name"],
        provider_id: provider_id,
        inserted_at: timestamp,
        updated_at: timestamp
      }
    end

    assert {3, [7_001, 7_002, 7_003]} =
             ContentUpsert.upsert_batched(streams, provider.id, %{}, now,
               schema: Movie,
               stream_id_field: :stream_id,
               attrs_fn: attrs_fn,
               category_fn: fn _batch, _returned, _lookup -> [] end,
               content_type: "movie"
             )

    assert Repo.get_by!(Movie, provider_id: provider.id, stream_id: 7_001).name == "First"
  end

  test "updates existing content without replacing its catalog identity" do
    provider = provider_fixture(user_fixture())
    movie = movie_fixture(provider, %{stream_id: 7_001, name: "Before"})
    now = ~U[2026-07-30 15:00:00Z]

    attrs_fn = fn stream, provider_id, timestamp ->
      %{
        stream_id: stream["stream_id"],
        name: stream["name"],
        provider_id: provider_id,
        inserted_at: timestamp,
        updated_at: timestamp
      }
    end

    assert {1, [7_001]} =
             ContentUpsert.upsert_batched(
               [%{"stream_id" => 7_001, "name" => "After"}],
               provider.id,
               %{},
               now,
               schema: Movie,
               stream_id_field: :stream_id,
               attrs_fn: attrs_fn,
               category_fn: fn _batch, _returned, _lookup -> [] end,
               content_type: "movie"
             )

    updated = Repo.get_by!(Movie, provider_id: provider.id, stream_id: 7_001)
    assert updated.name == "After"
    assert updated.catalog_item_id == movie.catalog_item_id

    assert Repo.aggregate(
             from(item in CatalogItem, where: item.provider_id == ^provider.id),
             :count
           ) == 1
  end

  test "supports an explicit non-stream content identity" do
    provider = provider_fixture(user_fixture())
    now = ~U[2026-07-30 15:00:00Z]

    attrs_fn = fn series, provider_id, timestamp ->
      %{
        series_id: series["series_id"],
        name: series["name"],
        provider_id: provider_id,
        inserted_at: timestamp,
        updated_at: timestamp
      }
    end

    assert {2, [8_001, 8_002]} =
             ContentUpsert.upsert_batched(
               [
                 %{"series_id" => 8_001, "name" => "First"},
                 %{"series_id" => 8_002, "name" => "Second"}
               ],
               provider.id,
               %{},
               now,
               schema: Series,
               stream_id_field: :series_id,
               attrs_fn: attrs_fn,
               category_fn: fn _batch, _returned, _lookup -> [] end,
               content_type: "series"
             )

    assert Repo.get_by!(Series, provider_id: provider.id, series_id: 8_001).name == "First"
  end
end
