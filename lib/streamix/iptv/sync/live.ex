defmodule Streamix.Iptv.Sync.Live do
  @moduledoc """
  Live channel synchronization from Xtream Codes API.
  """

  alias Streamix.Iptv.{LiveChannel, Provider, XtreamClient}
  alias Streamix.Iptv.Sync.Helpers
  alias Streamix.Iptv.Sync.Normalizers.LiveChannel, as: LiveChannelNormalizer
  alias Streamix.Repo

  require Logger

  @sync_opts [
    schema: LiveChannel,
    stream_id_field: :stream_id,
    content_type: "live_channel"
  ]

  @doc """
  Syncs live channels for a provider.
  """
  def sync_live_channels(%Provider{} = provider) do
    Logger.info("Syncing live channels for provider #{provider.id}")

    case XtreamClient.get_live_streams(provider.url, provider.username, provider.password) do
      {:ok, streams} ->
        category_lookup = Helpers.build_category_lookup(provider.id, "live")
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        upsert_opts =
          @sync_opts
          |> Keyword.put(:attrs_fn, &LiveChannelNormalizer.attrs/3)
          |> Keyword.put(:category_fn, &build_category_assocs/3)
          |> Keyword.put(:type, :live)
          |> Keyword.put(:provider, provider)

        {count, all_stream_ids} =
          Helpers.upsert_content_batched(streams, provider.id, category_lookup, now, upsert_opts)

        deleted_count = Helpers.delete_orphaned_content(provider.id, all_stream_ids, @sync_opts)

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

  defp build_category_assocs(streams, returned, category_lookup) do
    Helpers.build_category_assocs(streams, returned, category_lookup, fk_column: :live_channel_id)
  end
end
