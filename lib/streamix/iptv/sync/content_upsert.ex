defmodule Streamix.Iptv.Sync.ContentUpsert do
  @moduledoc """
  Generic batched content upsert and orphan cleanup for provider sync.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.CatalogItem
  alias Streamix.Iptv.Content.SourceEquivalence
  alias Streamix.Iptv.Sync.CategoryAssocs
  alias Streamix.Repo

  @batch_size 500

  def batch_size, do: @batch_size

  @doc """
  Generic batched upsert for content types.
  """
  def upsert_batched(streams, provider_id, category_lookup, now, opts) do
    schema = Keyword.fetch!(opts, :schema)
    stream_id_field = Keyword.fetch!(opts, :stream_id_field)
    attrs_fn = Keyword.fetch!(opts, :attrs_fn)
    category_fn = Keyword.fetch!(opts, :category_fn)
    catalog_content_type = Keyword.fetch!(opts, :content_type)
    telemetry_type = Keyword.get(opts, :type)
    provider = Keyword.get(opts, :provider)
    stream_id_key = Atom.to_string(stream_id_field)

    # Dedupe by the conflict target. Some panels (e.g. grupobrtv) return the
    # same stream_id more than once; if two land in the same insert_all batch,
    # Postgres aborts with `cardinality_violation: ON CONFLICT DO UPDATE
    # command cannot affect row a second time`, which killed the whole movie
    # sync and left the catalog on stale upstream ids.
    streams = Enum.uniq_by(streams, & &1[stream_id_key])
    total_batches = ceil(length(streams) / @batch_size)

    batch_context = %{
      attrs_fn: attrs_fn,
      catalog_content_type: catalog_content_type,
      category_fn: category_fn,
      category_lookup: category_lookup,
      now: now,
      provider_id: provider_id,
      schema: schema,
      stream_id_field: stream_id_field,
      stream_id_key: stream_id_key
    }

    streams
    |> Enum.chunk_every(@batch_size)
    |> Enum.with_index(1)
    |> Enum.reduce({0, []}, fn {batch, batch_num}, {acc_count, acc_ids} ->
      batch_start = System.monotonic_time()
      batch_stream_ids = Enum.map(batch, & &1[stream_id_key])

      inserted =
        transact_batch!(fn ->
          upsert_batch(batch, batch_stream_ids, batch_context)
        end)

      maybe_emit_batch_telemetry(
        provider,
        telemetry_type,
        inserted,
        batch_start,
        batch_num,
        total_batches
      )

      {acc_count + inserted, Enum.reverse(batch_stream_ids, acc_ids)}
    end)
    |> then(fn {count, ids} -> {count, Enum.reverse(ids)} end)
  end

  defp upsert_batch(batch, batch_stream_ids, context) do
    ci_map =
      build_catalog_item_map(
        context.schema,
        context.provider_id,
        context.stream_id_field,
        batch_stream_ids,
        context.catalog_content_type,
        context.now
      )

    content_data =
      Enum.map(batch, fn stream ->
        sid = stream[context.stream_id_key]

        stream
        |> context.attrs_fn.(context.provider_id, context.now)
        |> Map.put(:catalog_item_id, ci_map[sid])
      end)

    {inserted, returned} =
      Repo.insert_all(context.schema, content_data,
        on_conflict: {:replace_all_except, [:id, :inserted_at, :catalog_item_id]},
        conflict_target: [:provider_id, context.stream_id_field],
        returning: [:id, context.stream_id_field, :catalog_item_id]
      )

    catalog_item_ids = Enum.map(returned, & &1.catalog_item_id) |> Enum.reject(&is_nil/1)
    content_ids = Enum.map(returned, & &1.id)
    category_assocs = context.category_fn.(batch, returned, context.category_lookup)

    {:ok, _linked_count} = SourceEquivalence.reconcile_content_ids(context.schema, content_ids)
    CategoryAssocs.rebuild_diff(catalog_item_ids, category_assocs)

    {:ok, inserted}
  end

  defp transact_batch!(fun) do
    case Repo.transact(fun) do
      {:ok, result} ->
        result

      {:error, reason} ->
        raise "content upsert batch transaction failed: #{inspect(reason)}"
    end
  end

  defp build_catalog_item_map(
         schema,
         provider_id,
         stream_id_field,
         batch_stream_ids,
         content_type,
         now
       ) do
    existing_ci_map =
      fetch_existing_ci_map(schema, provider_id, stream_id_field, batch_stream_ids)

    new_stream_ids = Enum.reject(batch_stream_ids, &Map.has_key?(existing_ci_map, &1))

    new_catalog_item_ids =
      pre_create_catalog_items(length(new_stream_ids), content_type, provider_id, now)

    new_ci_map = Enum.zip(new_stream_ids, new_catalog_item_ids) |> Map.new()

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
end
