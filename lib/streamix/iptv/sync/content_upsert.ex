defmodule Streamix.Iptv.Sync.ContentUpsert do
  @moduledoc """
  Generic batched content upsert and orphan cleanup for provider sync.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{CatalogItem, Series}
  alias Streamix.Iptv.Sync.CategoryAssocs
  alias Streamix.Repo

  @batch_size 500

  def batch_size, do: @batch_size

  @doc """
  Generic batched upsert for content types.
  """
  def upsert_batched(streams, provider_id, category_lookup, now, opts) do
    schema = Keyword.fetch!(opts, :schema)
    attrs_fn = Keyword.fetch!(opts, :attrs_fn)
    category_fn = Keyword.fetch!(opts, :category_fn)
    catalog_content_type = Keyword.fetch!(opts, :content_type)
    telemetry_type = Keyword.get(opts, :type)
    provider = Keyword.get(opts, :provider)
    stream_id_field = if schema == Series, do: :series_id, else: :stream_id
    stream_id_key = if stream_id_field == :series_id, do: "series_id", else: "stream_id"

    # Dedupe by the conflict target. Some panels (e.g. grupobrtv) return the
    # same stream_id more than once; if two land in the same insert_all batch,
    # Postgres aborts with `cardinality_violation: ON CONFLICT DO UPDATE
    # command cannot affect row a second time`, which killed the whole movie
    # sync and left the catalog on stale upstream ids.
    streams = Enum.uniq_by(streams, & &1[stream_id_key])
    total_batches = ceil(length(streams) / @batch_size)

    existing_stream_ids =
      schema
      |> where(provider_id: ^provider_id)
      |> select([c], field(c, ^stream_id_field))
      |> Repo.all()
      |> MapSet.new()

    streams
    |> Enum.chunk_every(@batch_size)
    |> Enum.with_index(1)
    |> Enum.reduce({0, []}, fn {batch, batch_num}, {acc_count, acc_ids} ->
      batch_start = System.monotonic_time()
      batch_stream_ids = Enum.map(batch, & &1[stream_id_key])

      ci_map =
        build_catalog_item_map(
          schema,
          provider_id,
          stream_id_field,
          batch_stream_ids,
          existing_stream_ids,
          catalog_content_type,
          now
        )

      content_data =
        Enum.map(batch, fn stream ->
          sid = stream[stream_id_key]
          stream |> attrs_fn.(provider_id, now) |> Map.put(:catalog_item_id, ci_map[sid])
        end)

      {inserted, returned} =
        Repo.insert_all(schema, content_data,
          on_conflict: {:replace_all_except, [:id, :inserted_at, :catalog_item_id]},
          conflict_target: [:provider_id, stream_id_field],
          returning: [:id, stream_id_field, :catalog_item_id]
        )

      catalog_item_ids = Enum.map(returned, & &1.catalog_item_id) |> Enum.reject(&is_nil/1)
      category_assocs = category_fn.(batch, returned, category_lookup)

      CategoryAssocs.rebuild_diff(catalog_item_ids, category_assocs)

      maybe_emit_batch_telemetry(
        provider,
        telemetry_type,
        inserted,
        batch_start,
        batch_num,
        total_batches
      )

      {acc_count + inserted, batch_stream_ids ++ acc_ids}
    end)
    |> then(fn {count, ids} -> {count, Enum.reverse(ids)} end)
  end

  defp build_catalog_item_map(
         schema,
         provider_id,
         stream_id_field,
         batch_stream_ids,
         existing_stream_ids,
         content_type,
         now
       ) do
    new_stream_ids = Enum.reject(batch_stream_ids, &MapSet.member?(existing_stream_ids, &1))

    new_catalog_item_ids =
      pre_create_catalog_items(length(new_stream_ids), content_type, provider_id, now)

    new_ci_map = Enum.zip(new_stream_ids, new_catalog_item_ids) |> Map.new()

    existing_sids = Enum.filter(batch_stream_ids, &MapSet.member?(existing_stream_ids, &1))
    existing_ci_map = fetch_existing_ci_map(schema, provider_id, stream_id_field, existing_sids)

    Map.merge(existing_ci_map, new_ci_map)
  end

  defp maybe_emit_batch_telemetry(nil, _telemetry_type, _inserted, _start, _batch_num, _total),
    do: :ok

  defp maybe_emit_batch_telemetry(_provider, nil, _inserted, _start, _batch_num, _total), do: :ok

  defp maybe_emit_batch_telemetry(
         provider,
         telemetry_type,
         inserted,
         batch_start,
         batch_num,
         total_batches
       ) do
    batch_duration = System.monotonic_time() - batch_start

    :telemetry.execute(
      [:streamix, :sync, :batch],
      %{count: inserted, duration: batch_duration},
      %{provider_id: provider.id, type: telemetry_type, batch_number: batch_num}
    )

    :telemetry.execute(
      [:streamix, :sync, :batch_progress],
      %{
        percent: round(batch_num / total_batches * 100),
        batch: batch_num,
        total_batches: total_batches
      },
      %{provider_id: provider.id, type: telemetry_type}
    )
  end

  defp fetch_existing_ci_map(_schema, _provider_id, _stream_id_field, []), do: %{}

  defp fetch_existing_ci_map(schema, provider_id, stream_id_field, existing_sids) do
    schema
    |> where(provider_id: ^provider_id)
    |> where([c], field(c, ^stream_id_field) in ^existing_sids)
    |> select([c], {field(c, ^stream_id_field), c.catalog_item_id})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Pre-creates N catalog_items of the given content_type and returns their IDs.
  """
  def pre_create_catalog_items(0, _content_type, _provider_id, _now), do: []

  def pre_create_catalog_items(count, content_type, provider_id, now) do
    entries =
      for _ <- 1..count do
        %{content_type: content_type, provider_id: provider_id, inserted_at: now, updated_at: now}
      end

    {_count, items} = Repo.insert_all(CatalogItem, entries, returning: [:id])
    Enum.map(items, & &1.id)
  end

  @doc """
  Generic orphan deletion for content types.
  """
  def delete_orphaned_content(provider_id, current_stream_ids, opts) do
    schema = Keyword.fetch!(opts, :schema)
    table_name = Keyword.fetch!(opts, :table_name)

    Repo.query!(
      """
      DELETE FROM item_categories
      WHERE catalog_item_id IN (
        SELECT catalog_item_id FROM #{table_name}
        WHERE provider_id = $1 AND stream_id != ALL($2)
      )
      """,
      [provider_id, current_stream_ids]
    )

    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT catalog_item_id FROM #{table_name}
        WHERE provider_id = $1 AND stream_id != ALL($2)
        """,
        [provider_id, current_stream_ids]
      )

    orphan_catalog_ids = Enum.map(rows, fn [id] -> id end)

    {count, _} =
      schema
      |> where([c], c.provider_id == ^provider_id)
      |> where([c], c.stream_id not in ^current_stream_ids)
      |> Repo.delete_all()

    if orphan_catalog_ids != [] do
      Repo.query!("DELETE FROM catalog_items WHERE id = ANY($1)", [orphan_catalog_ids])
    end

    count
  end
end
