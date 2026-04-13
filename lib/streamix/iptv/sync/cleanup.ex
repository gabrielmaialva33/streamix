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
  Cleans up favorites and watch progress that reference deleted content.
  Removes entries whose catalog_item no longer has a valid content row.
  """
  def cleanup_orphaned_user_data do
    Logger.info("Cleaning up orphaned favorites and watch progress")

    # Find catalog_items that have no content row
    orphaned_catalog_ids = find_orphaned_catalog_item_ids()

    if orphaned_catalog_ids == [] do
      {:ok, %{favorites: 0, watch_history: 0}}
    else
      {fav_count, _} =
        Favorite
        |> where([f], f.catalog_item_id in ^orphaned_catalog_ids)
        |> Repo.delete_all()

      {hist_count, _} =
        WatchProgress
        |> where([wp], wp.catalog_item_id in ^orphaned_catalog_ids)
        |> Repo.delete_all()

      if fav_count > 0 or hist_count > 0 do
        Logger.info(
          "Removed #{fav_count} orphaned favorites, #{hist_count} orphaned watch progress entries"
        )
      end

      {:ok, %{favorites: fav_count, watch_history: hist_count}}
    end
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
