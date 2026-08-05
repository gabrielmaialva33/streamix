defmodule Streamix.Iptv.Sync.Cleanup do
  @moduledoc """
  Cleanup of orphaned catalog items and their dependent user data.

  Provider syncs use a bounded, provider-scoped sweep. The scheduled cleanup
  worker can run an unbounded sweep across all providers.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{CatalogItem, Favorite, WatchProgress}
  alias Streamix.Repo
  alias Streamix.WatchParty

  @delete_chunk 500
  @query_timeout :timer.seconds(60)
  @empty_counts %{favorites: 0, watch_history: 0, watch_party_rooms: 0, catalog_items: 0}

  require Logger

  @doc """
  Cleans up orphaned catalog items:

    1. Removes `favorites` and `watch_progress` entries whose
       `catalog_item_id` no longer points at an existing content row.
    2. Removes the now-dangling `catalog_items` themselves so the table
       doesn't grow unbounded.

  Pass a provider ID to scope the sweep to that provider. The optional
  `:limit` bounds how many catalog items are cleaned in this invocation.

  Each chunk runs in its own transaction. Completed chunks stay committed if
  a later chunk fails, making retries cheap and idempotent.
  """
  def cleanup_orphaned_user_data(provider_id \\ nil, opts \\ []) do
    limit = cleanup_limit!(opts)

    Logger.info(
      "Cleaning up orphaned favorites, watch progress, and catalog_items" <>
        cleanup_scope(provider_id, limit)
    )

    provider_id
    |> find_orphaned_catalog_item_ids(limit)
    |> do_cleanup()
  end

  defp do_cleanup([]), do: {:ok, @empty_counts}

  defp do_cleanup(orphaned_catalog_ids) do
    result =
      orphaned_catalog_ids
      |> Enum.chunk_every(@delete_chunk)
      |> Enum.reduce_while({:ok, @empty_counts}, fn chunk, {:ok, accumulated} ->
        case cleanup_chunk(chunk) do
          {:ok, counts} ->
            {:cont, {:ok, merge_counts(accumulated, counts)}}

          {:error, reason} ->
            {:halt, {:error, {:chunk_failed, reason, accumulated}}}
        end
      end)

    log_result(result)
    result
  end

  # Favorites, watch_progress, and watch_party_rooms all cascade from
  # catalog_items, but deleting them explicitly gives us useful counts.
  # A room pointing at deleted content is itself dead; dropping it also
  # cascades its participants and messages.
  defp delete_chunk(chunk) do
    {fav, _} =
      Favorite
      |> where([f], f.catalog_item_id in ^chunk)
      |> Repo.delete_all(timeout: @query_timeout)

    {hist, _} =
      WatchProgress
      |> where([wp], wp.catalog_item_id in ^chunk)
      |> Repo.delete_all(timeout: @query_timeout)

    rooms =
      WatchParty.delete_rooms_by_catalog_item_ids(chunk, timeout: @query_timeout)

    {ci, _} =
      CatalogItem
      |> where([c], c.id in ^chunk)
      |> Repo.delete_all(timeout: @query_timeout)

    %{
      favorites: fav,
      watch_history: hist,
      watch_party_rooms: rooms,
      catalog_items: ci
    }
  end

  defp cleanup_chunk(chunk) do
    Repo.transaction(fn -> delete_chunk(chunk) end, timeout: @query_timeout)
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp merge_counts(left, right) do
    Map.new(@empty_counts, fn {key, _value} ->
      {key, Map.fetch!(left, key) + Map.fetch!(right, key)}
    end)
  end

  defp log_result({:ok, counts}) do
    if Enum.any?(counts, fn {_key, value} -> value > 0 end) do
      Logger.info(
        "Cleanup: #{counts.favorites} favorites, #{counts.watch_history} watch_progress, " <>
          "#{counts.watch_party_rooms} watch_party_rooms, #{counts.catalog_items} catalog_items removed"
      )
    end
  end

  defp log_result({:error, {:chunk_failed, reason, counts}}) do
    Logger.error(
      "Cleanup stopped after #{counts.catalog_items} catalog_items: #{inspect(reason)}"
    )
  end

  # Single NOT EXISTS query. The previous implementation materialised every
  # catalog_items id + every content-table catalog_item_id (5 separate
  # Repo.all calls) just to compute set-difference in Elixir. With 1M+
  # rows that was a multi-hundred-MB spike during cleanup; Postgres can
  # answer the same question with one semi-join per content table.
  defp find_orphaned_catalog_item_ids(provider_id, limit) do
    CatalogItem
    |> where(
      [ci],
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
      )
    )
    |> maybe_scope_provider(provider_id)
    |> order_by([ci], asc: ci.id)
    |> maybe_limit(limit)
    |> select([ci], ci.id)
    |> Repo.all(timeout: @query_timeout)
  end

  defp maybe_scope_provider(query, nil), do: query

  defp maybe_scope_provider(query, provider_id),
    do: where(query, [ci], ci.provider_id == ^provider_id)

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp cleanup_limit!(opts) do
    case Keyword.get(opts, :limit) do
      nil ->
        nil

      limit when is_integer(limit) and limit > 0 ->
        limit

      invalid ->
        raise ArgumentError, "expected :limit to be a positive integer, got: #{inspect(invalid)}"
    end
  end

  defp cleanup_scope(nil, nil), do: ""
  defp cleanup_scope(nil, limit), do: " (limit: #{limit})"
  defp cleanup_scope(provider_id, nil), do: " (provider: #{provider_id})"

  defp cleanup_scope(provider_id, limit),
    do: " (provider: #{provider_id}, limit: #{limit})"
end
