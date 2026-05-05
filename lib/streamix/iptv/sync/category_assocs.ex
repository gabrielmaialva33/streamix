defmodule Streamix.Iptv.Sync.CategoryAssocs do
  @moduledoc """
  Category lookup and `item_categories` association maintenance.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.Category
  alias Streamix.Repo

  @doc """
  Builds a lookup map of external_id -> database id for categories.
  """
  def build_lookup(provider_id, type) do
    Category
    |> where(provider_id: ^provider_id, type: ^type)
    |> select([c], {c.external_id, c.id})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Rebuilds category associations via `item_categories` using the content's
  `catalog_item_id`.
  """
  def rebuild_diff(catalog_item_ids, desired_assocs) when is_list(catalog_item_ids) do
    if Enum.empty?(catalog_item_ids) do
      :ok
    else
      do_rebuild_diff(catalog_item_ids, desired_assocs)
    end
  end

  defp do_rebuild_diff(catalog_item_ids, desired_assocs) do
    current_assocs =
      Repo.query!(
        "SELECT catalog_item_id, category_id FROM item_categories WHERE catalog_item_id = ANY($1)",
        [catalog_item_ids]
      )
      |> Map.get(:rows, [])
      |> MapSet.new(fn [ci_id, cat_id] -> {ci_id, cat_id} end)

    desired_set =
      desired_assocs
      |> Enum.map(fn assoc ->
        {Map.get(assoc, :catalog_item_id), Map.get(assoc, :category_id)}
      end)
      |> Enum.reject(fn {catalog_item_id, category_id} ->
        is_nil(catalog_item_id) or is_nil(category_id)
      end)
      |> MapSet.new()

    to_insert = MapSet.difference(desired_set, current_assocs)
    to_delete = MapSet.difference(current_assocs, desired_set)

    unless MapSet.size(to_delete) == 0 do
      to_delete
      |> MapSet.to_list()
      |> bulk_delete()
    end

    unless MapSet.size(to_insert) == 0 do
      new_assocs =
        to_insert
        |> MapSet.to_list()
        |> Enum.map(fn {ci_id, cat_id} ->
          %{catalog_item_id: ci_id, category_id: cat_id}
        end)

      Repo.insert_all("item_categories", new_assocs)
    end

    :ok
  end

  defp bulk_delete(pairs) do
    values_clause =
      pairs
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {_, i} -> "($#{i * 2 - 1}::bigint, $#{i * 2}::bigint)" end)

    params = Enum.flat_map(pairs, fn {ci_id, cat_id} -> [ci_id, cat_id] end)

    Repo.query!(
      """
      DELETE FROM item_categories
      WHERE (catalog_item_id, category_id) IN (VALUES #{values_clause})
      """,
      params
    )
  end

  @doc """
  Builds category associations from streams and returned entities.
  """
  def build(streams, returned_entities, category_lookup, _opts \\ []) do
    stream_to_ci_id =
      Map.new(returned_entities, fn entity ->
        sid = Map.get(entity, :stream_id) || Map.get(entity, :series_id)
        {sid, entity.catalog_item_id}
      end)

    streams
    |> Enum.flat_map(fn stream ->
      sid = stream["stream_id"] || stream["series_id"]
      ci_id = stream_to_ci_id[sid]
      cat_ext_id = to_string(stream["category_id"])
      category_id = category_lookup[cat_ext_id]

      if ci_id && category_id do
        [%{catalog_item_id: ci_id, category_id: category_id}]
      else
        []
      end
    end)
  end
end
