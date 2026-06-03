defmodule Streamix.Iptv.Sync.Cleanup do
  @moduledoc """
  Cleanup of orphaned user data (favorites and watch progress).
  Called after sync to remove references to deleted content.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{CatalogItem, Favorite, WatchProgress}
  alias Streamix.Repo
  alias Streamix.WatchParty.Room

  # Postgres caps a single statement at 32_767 bound parameters. An
  # `id in ^ids` delete with the full orphan set (tens of thousands after
  # a provider migration) blows past that, so every delete is chunked.
  @delete_chunk 5_000

  require Logger

  @doc """
  Cleans up after a content sync:

    1. Removes `favorites` and `watch_progress` entries whose
       `catalog_item_id` no longer points at an existing content row.
    2. Removes the now-dangling `catalog_items` themselves so the table
       doesn't grow unbounded.

  All steps run in a single transaction so a failure halfway through
  rolls back cleanly. The sweep is `O(catalog_items + content rows)`
  per call and is intended to run after a successful provider sync.
  """
  def cleanup_orphaned_user_data do
    Logger.info("Cleaning up orphaned favorites, watch progress, and catalog_items")

    Repo.transaction(fn ->
      orphaned_catalog_ids = find_orphaned_catalog_item_ids()
      do_cleanup(orphaned_catalog_ids)
    end)
  end

  defp do_cleanup([]),
    do: %{favorites: 0, watch_history: 0, watch_party_rooms: 0, catalog_items: 0}

  defp do_cleanup(orphaned_catalog_ids) do
    counts =
      orphaned_catalog_ids
      |> Enum.chunk_every(@delete_chunk)
      |> Enum.reduce(
        %{favorites: 0, watch_history: 0, watch_party_rooms: 0, catalog_items: 0},
        &delete_chunk/2
      )

    if Enum.any?(counts, fn {_k, v} -> v > 0 end) do
      Logger.info(
        "Cleanup: #{counts.favorites} favorites, #{counts.watch_history} watch_progress, " <>
          "#{counts.watch_party_rooms} watch_party_rooms, #{counts.catalog_items} catalog_items removed"
      )
    end

    counts
  end

  # Order matters: watch_party_rooms reference catalog_items with a
  # RESTRICT FK on a NOT NULL column, so the rooms must go before the
  # catalog_items or the delete aborts. Favorites/watch_progress cascade,
  # but we delete them explicitly to count them. A room pointing at deleted
  # content is itself dead — dropping it cascades its participants/messages.
  defp delete_chunk(chunk, acc) do
    {fav, _} = Favorite |> where([f], f.catalog_item_id in ^chunk) |> Repo.delete_all()
    {hist, _} = WatchProgress |> where([wp], wp.catalog_item_id in ^chunk) |> Repo.delete_all()
    {rooms, _} = Room |> where([r], r.catalog_item_id in ^chunk) |> Repo.delete_all()
    {ci, _} = CatalogItem |> where([c], c.id in ^chunk) |> Repo.delete_all()

    %{
      favorites: acc.favorites + fav,
      watch_history: acc.watch_history + hist,
      watch_party_rooms: acc.watch_party_rooms + rooms,
      catalog_items: acc.catalog_items + ci
    }
  end

  # Single NOT EXISTS query. The previous implementation materialised every
  # catalog_items id + every content-table catalog_item_id (5 separate
  # Repo.all calls) just to compute set-difference in Elixir. With 1M+
  # rows that was a multi-hundred-MB spike during cleanup; Postgres can
  # answer the same question with one semi-join per content table.
  defp find_orphaned_catalog_item_ids do
    from(ci in CatalogItem,
      where:
        fragment(
          """
          NOT EXISTS (SELECT 1 FROM live_channels lc WHERE lc.catalog_item_id = ?)
            AND NOT EXISTS (SELECT 1 FROM movies m WHERE m.catalog_item_id = ?)
            AND NOT EXISTS (SELECT 1 FROM series s WHERE s.catalog_item_id = ?)
            AND NOT EXISTS (SELECT 1 FROM episodes e WHERE e.catalog_item_id = ?)
          """,
          ci.id,
          ci.id,
          ci.id,
          ci.id
        ),
      select: ci.id
    )
    |> Repo.all()
  end
end
