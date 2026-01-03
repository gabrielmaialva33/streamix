defmodule Streamix.Iptv.Sync.Live do
  @moduledoc """
  Live channel synchronization from Xtream Codes API.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{LiveChannel, Provider, XtreamClient}
  alias Streamix.Iptv.Sync.Helpers
  alias Streamix.Repo

  require Logger

  @doc """
  Syncs live channels for a provider.
  """
  def sync_live_channels(%Provider{} = provider) do
    Logger.info("Syncing live channels for provider #{provider.id}")

    case XtreamClient.get_live_streams(provider.url, provider.username, provider.password) do
      {:ok, streams} ->
        category_lookup = Helpers.build_category_lookup(provider.id, "live")
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        # Upsert in batches and collect all stream_ids
        {count, all_stream_ids} =
          upsert_live_channels_batched(streams, provider.id, category_lookup, now)

        # Delete orphaned channels
        deleted_count = delete_orphaned_live_channels(provider.id, all_stream_ids)

        now_utc = DateTime.utc_now() |> DateTime.truncate(:second)

        provider
        |> Provider.sync_changeset(%{live_channels_count: count, live_synced_at: now_utc})
        |> Repo.update()

        Logger.info("Synced #{count} live channels, removed #{deleted_count} orphaned")
        {:ok, count}

      {:error, reason} ->
        {:error, {:live_sync_failed, reason}}
    end
  end

  defp upsert_live_channels_batched(streams, provider_id, category_lookup, now) do
    streams
    |> Enum.chunk_every(Helpers.batch_size())
    |> Enum.reduce({0, []}, fn batch, {acc_count, acc_ids} ->
      channels_data = Enum.map(batch, &live_channel_attrs(&1, provider_id, now))

      {inserted, returned} =
        Repo.insert_all(LiveChannel, channels_data,
          on_conflict: {:replace_all_except, [:id, :inserted_at]},
          conflict_target: [:provider_id, :stream_id],
          returning: [:id, :stream_id]
        )

      # Rebuild category associations for this batch
      rebuild_live_category_assocs(batch, returned, category_lookup)

      batch_stream_ids = Enum.map(batch, & &1["stream_id"])
      {acc_count + inserted, acc_ids ++ batch_stream_ids}
    end)
  end

  defp rebuild_live_category_assocs(streams, returned_channels, category_lookup) do
    channel_ids = Enum.map(returned_channels, & &1.id)

    # Delete existing associations for these channels
    Repo.query!(
      "DELETE FROM live_channel_categories WHERE live_channel_id = ANY($1)",
      [channel_ids]
    )

    # Build new associations
    category_assocs = build_live_category_assocs(streams, returned_channels, category_lookup)

    unless Enum.empty?(category_assocs) do
      Repo.insert_all("live_channel_categories", category_assocs)
    end
  end

  defp delete_orphaned_live_channels(provider_id, current_stream_ids) do
    # First delete category associations for orphaned channels
    Repo.query!(
      """
      DELETE FROM live_channel_categories
      WHERE live_channel_id IN (
        SELECT id FROM live_channels
        WHERE provider_id = $1 AND stream_id != ALL($2)
      )
      """,
      [provider_id, current_stream_ids]
    )

    # Then delete the orphaned channels
    {count, _} =
      LiveChannel
      |> where([c], c.provider_id == ^provider_id)
      |> where([c], c.stream_id not in ^current_stream_ids)
      |> Repo.delete_all()

    count
  end

  defp live_channel_attrs(stream, provider_id, now) do
    %{
      stream_id: stream["stream_id"],
      name: stream["name"] || "Unknown",
      stream_icon: stream["stream_icon"],
      epg_channel_id: stream["epg_channel_id"],
      tv_archive: stream["tv_archive"] == 1,
      tv_archive_duration: stream["tv_archive_duration"],
      direct_source: stream["direct_source"],
      provider_id: provider_id,
      inserted_at: now,
      updated_at: now
    }
  end

  defp build_live_category_assocs(streams, returned_channels, category_lookup) do
    stream_to_db_id =
      Map.new(returned_channels, fn %{id: id, stream_id: stream_id} -> {stream_id, id} end)

    streams
    |> Enum.flat_map(fn stream ->
      channel_id = stream_to_db_id[stream["stream_id"]]
      cat_ext_id = to_string(stream["category_id"])
      category_id = category_lookup[cat_ext_id]

      if channel_id && category_id do
        [%{live_channel_id: channel_id, category_id: category_id}]
      else
        []
      end
    end)
  end
end
