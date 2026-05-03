defmodule Streamix.Iptv.Sync.Cleanup do
  @moduledoc """
  Cleanup of orphaned user data (favorites and watch progress).
  Called after sync to remove references to deleted content.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{CatalogItem, Favorite, WatchProgress}
  alias Streamix.Repo

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

  defp do_cleanup([]), do: %{favorites: 0, watch_history: 0, catalog_items: 0}

  defp do_cleanup(orphaned_catalog_ids) do
    {fav_count, _} =
      Favorite
      |> where([f], f.catalog_item_id in ^orphaned_catalog_ids)
      |> Repo.delete_all()

    {hist_count, _} =
      WatchProgress
      |> where([wp], wp.catalog_item_id in ^orphaned_catalog_ids)
      |> Repo.delete_all()

    ci_count = delete_catalog_items_in_chunks(orphaned_catalog_ids)

    if fav_count + hist_count + ci_count > 0 do
      Logger.info(
        "Cleanup: #{fav_count} favorites, #{hist_count} watch_progress, " <>
          "#{ci_count} catalog_items removed"
      )
    end

    %{favorites: fav_count, watch_history: hist_count, catalog_items: ci_count}
  end

  # Chunked to dodge the Postgres parameter limit (32k) on big sweeps.
  defp delete_catalog_items_in_chunks(ids) do
    ids
    |> Enum.chunk_every(5_000)
    |> Enum.reduce(0, fn chunk, acc ->
      {n, _} =
        CatalogItem
        |> where([c], c.id in ^chunk)
        |> Repo.delete_all()

      acc + n
    end)
  end

  defp find_orphaned_catalog_item_ids do
    # Catalog items where the content row no longer exists
    all_catalog_ids =
      CatalogItem
      |> select([ci], ci.id)
      |> Repo.all()

    # For each content type, find catalog_items that still have content
    valid_ids =
      ~w(live_channel movie series episode)
      |> Enum.flat_map(fn type ->
        schema = content_schema(type)

        schema
        |> where([c], not is_nil(c.catalog_item_id))
        |> select([c], c.catalog_item_id)
        |> Repo.all()
      end)
      |> MapSet.new()

    Enum.reject(all_catalog_ids, &MapSet.member?(valid_ids, &1))
  end

  defp content_schema("live_channel"), do: Streamix.Iptv.LiveChannel
  defp content_schema("movie"), do: Streamix.Iptv.Movie
  defp content_schema("series"), do: Streamix.Iptv.Series
  defp content_schema("episode"), do: Streamix.Iptv.Episode
end
