defmodule Streamix.Iptv.Sync.Categories do
  @moduledoc """
  Category synchronization from Xtream Codes API.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{AdultDetector, Category, Provider, XtreamClient}
  alias Streamix.Repo

  require Logger

  @doc """
  Syncs all categories (live, vod, series) for a provider.
  """
  def sync_categories(%Provider{} = provider) do
    Logger.info("Syncing categories for provider #{provider.id}")

    with {:ok, live_cats} <-
           XtreamClient.get_live_categories(provider.url, provider.username, provider.password),
         {:ok, vod_cats} <-
           XtreamClient.get_vod_categories(provider.url, provider.username, provider.password),
         {:ok, series_cats} <-
           XtreamClient.get_series_categories(provider.url, provider.username, provider.password) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      all_categories =
        Enum.map(live_cats, &category_attrs(&1, "live", provider.id, now)) ++
          Enum.map(vod_cats, &category_attrs(&1, "vod", provider.id, now)) ++
          Enum.map(series_cats, &category_attrs(&1, "series", provider.id, now))

      # Upsert categories
      {count, _} =
        Repo.insert_all(Category, all_categories,
          on_conflict: {:replace, [:name, :is_adult, :updated_at]},
          conflict_target: [:provider_id, :external_id, :type]
        )

      # Delete orphaned categories (no longer in API response)
      current_external_ids = Enum.map(all_categories, & &1.external_id)

      deleted_count = delete_orphaned_categories(provider.id, current_external_ids)

      Logger.info("Synced #{count} categories, removed #{deleted_count} orphaned")
      {:ok, count}
    end
  end

  defp delete_orphaned_categories(provider_id, current_external_ids) do
    {count, _} =
      Category
      |> where([c], c.provider_id == ^provider_id)
      |> where([c], c.external_id not in ^current_external_ids)
      |> Repo.delete_all()

    count
  end

  defp category_attrs(cat, type, provider_id, now) do
    name = cat["category_name"] || "Unknown"

    %{
      external_id: to_string(cat["category_id"]),
      name: name,
      type: type,
      is_adult: AdultDetector.adult_category?(name),
      provider_id: provider_id,
      inserted_at: now,
      updated_at: now
    }
  end
end
