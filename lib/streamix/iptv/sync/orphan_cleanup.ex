defmodule Streamix.Iptv.Sync.OrphanCleanup do
  @moduledoc """
  Atomically removes provider content that disappeared from an upstream catalog.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.CatalogItem
  alias Streamix.Repo

  @spec delete(pos_integer(), [integer()], keyword()) :: non_neg_integer()
  def delete(provider_id, current_stream_ids, opts) do
    schema = Keyword.fetch!(opts, :schema)
    stream_id_field = Keyword.fetch!(opts, :stream_id_field)

    provider_content =
      schema
      |> where([content], content.provider_id == ^provider_id)
      |> excluding_current_ids(stream_id_field, current_stream_ids)

    case Repo.transact(fn -> delete_provider_content(provider_content) end) do
      {:ok, count} ->
        count

      {:error, reason} ->
        raise "orphan cleanup transaction failed: #{inspect(reason)}"
    end
  end

  defp excluding_current_ids(query, _stream_id_field, []), do: query

  defp excluding_current_ids(query, stream_id_field, current_stream_ids) do
    where(query, [content], field(content, ^stream_id_field) not in ^current_stream_ids)
  end

  defp delete_provider_content(provider_content) do
    orphan_catalog_ids =
      provider_content
      |> select([content], content.catalog_item_id)
      |> Repo.all()
      |> Enum.reject(&is_nil/1)

    delete_category_associations(orphan_catalog_ids)
    {count, _} = Repo.delete_all(provider_content)
    delete_catalog_items(orphan_catalog_ids)

    {:ok, count}
  end

  defp delete_category_associations([]), do: :ok

  defp delete_category_associations(catalog_item_ids) do
    from(assoc in "item_categories", where: assoc.catalog_item_id in ^catalog_item_ids)
    |> Repo.delete_all()

    :ok
  end

  defp delete_catalog_items([]), do: :ok

  defp delete_catalog_items(catalog_item_ids) do
    from(item in CatalogItem, where: item.id in ^catalog_item_ids)
    |> Repo.delete_all()

    :ok
  end
end
