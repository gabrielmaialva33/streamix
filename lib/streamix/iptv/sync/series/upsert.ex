defmodule Streamix.Iptv.Sync.Series.Upsert do
  @moduledoc """
  Series list synchronization, category association rebuilds, and orphan cleanup.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Provider, Series, XtreamClient}
  alias Streamix.Iptv.Sync.Helpers
  alias Streamix.Repo

  require Logger

  @doc """
  Syncs series without details for a provider.
  """
  def sync_series(%Provider{} = provider) do
    Logger.info("Syncing series for provider #{provider.id}")

    case XtreamClient.get_series(provider.url, provider.username, provider.password) do
      {:ok, series_list} ->
        sync_series_list(provider, series_list)

      {:error, reason} ->
        {:error, {:series_sync_failed, reason}}
    end
  end

  defp sync_series_list(provider, series_list) do
    category_lookup = Helpers.build_category_lookup(provider.id, "series")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, all_series_ids} =
      upsert_series_batched(series_list, provider.id, category_lookup, now)

    Helpers.sync_genres_and_credits(
      series_list,
      provider.id,
      Series,
      "series_genres",
      "series_id",
      credits_table: "series_credits",
      stream_id_key: "series_id"
    )

    deleted_count = delete_orphaned_series(provider.id, all_series_ids)
    now_utc = DateTime.utc_now() |> DateTime.truncate(:second)

    provider
    |> Provider.sync_changeset(%{series_count: count, series_synced_at: now_utc})
    |> Repo.update()

    Logger.info("Synced #{count} series, removed #{deleted_count} orphaned")
    {:ok, count}
  end

  defp upsert_series_batched(series_list, provider_id, category_lookup, now) do
    existing_series_ids =
      Series
      |> where(provider_id: ^provider_id)
      |> select([s], s.series_id)
      |> Repo.all()
      |> MapSet.new()

    series_list
    # Some panels list the same series_id more than once in a single
    # payload. insert_all's ON CONFLICT can't touch the same
    # (provider_id, series_id) row twice within one command, so a dup in a
    # batch aborts the whole series sync with Postgres 21000
    # (cardinality_violation). Dedupe up front — first occurrence wins.
    |> Enum.uniq_by(& &1["series_id"])
    |> Enum.chunk_every(Helpers.batch_size())
    |> Enum.reduce({0, []}, fn batch, {acc_count, acc_ids} ->
      batch_series_ids = Enum.map(batch, & &1["series_id"])

      ci_map =
        build_catalog_item_map(batch_series_ids, existing_series_ids, provider_id, now)

      series_data =
        Enum.map(batch, fn series ->
          series
          |> series_attrs(provider_id, now)
          |> Map.put(:catalog_item_id, ci_map[series["series_id"]])
        end)

      {inserted, returned} =
        Repo.insert_all(Series, series_data,
          on_conflict: {:replace_all_except, [:id, :inserted_at, :catalog_item_id]},
          conflict_target: [:provider_id, :series_id],
          returning: [:id, :series_id, :catalog_item_id]
        )

      catalog_item_ids = Enum.map(returned, & &1.catalog_item_id) |> Enum.reject(&is_nil/1)
      category_assocs = build_series_category_assocs(batch, returned, category_lookup)

      Helpers.rebuild_category_assocs_diff(catalog_item_ids, category_assocs)

      {acc_count + inserted, acc_ids ++ batch_series_ids}
    end)
  end

  defp build_catalog_item_map(batch_series_ids, existing_series_ids, provider_id, now) do
    new_series_ids = Enum.reject(batch_series_ids, &MapSet.member?(existing_series_ids, &1))

    new_ci_ids =
      Helpers.pre_create_catalog_items(length(new_series_ids), "series", provider_id, now)

    new_ci_map = Enum.zip(new_series_ids, new_ci_ids) |> Map.new()

    existing_series_ids =
      Enum.filter(batch_series_ids, &MapSet.member?(existing_series_ids, &1))

    existing_ci_map = fetch_existing_catalog_item_map(provider_id, existing_series_ids)

    Map.merge(existing_ci_map, new_ci_map)
  end

  defp fetch_existing_catalog_item_map(_provider_id, []), do: %{}

  defp fetch_existing_catalog_item_map(provider_id, existing_series_ids) do
    Series
    |> where(provider_id: ^provider_id)
    |> where([s], s.series_id in ^existing_series_ids)
    |> select([s], {s.series_id, s.catalog_item_id})
    |> Repo.all()
    |> Map.new()
  end

  defp delete_orphaned_series(provider_id, current_series_ids) do
    Repo.query!(
      """
      DELETE FROM item_categories
      WHERE catalog_item_id IN (
        SELECT catalog_item_id FROM series
        WHERE provider_id = $1 AND series_id != ALL($2)
      )
      """,
      [provider_id, current_series_ids]
    )

    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT catalog_item_id FROM series
        WHERE provider_id = $1 AND series_id != ALL($2)
        """,
        [provider_id, current_series_ids]
      )

    orphan_catalog_ids = Enum.map(rows, fn [id] -> id end)

    {count, _} =
      Series
      |> where([s], s.provider_id == ^provider_id)
      |> where([s], s.series_id not in ^current_series_ids)
      |> Repo.delete_all()

    if orphan_catalog_ids != [] do
      Repo.query!(
        "DELETE FROM catalog_items WHERE id = ANY($1)",
        [orphan_catalog_ids]
      )
    end

    count
  end

  defp series_attrs(series, provider_id, now) do
    %{
      series_id: series["series_id"],
      name: series["name"] || "Unknown",
      title: series["title"],
      year: Helpers.parse_year(series["year"]),
      cover: series["cover"],
      rating: Helpers.parse_decimal(series["rating"]),
      plot: series["plot"],
      youtube_trailer: series["youtube_trailer"],
      tmdb_id: Helpers.to_string_or_nil(series["tmdb_id"]),
      provider_id: provider_id,
      inserted_at: now,
      updated_at: now
    }
  end

  defp build_series_category_assocs(series_list, returned_series, category_lookup) do
    series_to_ci_id =
      Map.new(returned_series, fn entity -> {entity.series_id, entity.catalog_item_id} end)

    series_list
    |> Enum.flat_map(fn series ->
      ci_id = series_to_ci_id[series["series_id"]]
      cat_ext_id = to_string(series["category_id"])
      category_id = category_lookup[cat_ext_id]

      if ci_id && category_id do
        [%{catalog_item_id: ci_id, category_id: category_id}]
      else
        []
      end
    end)
  end
end
