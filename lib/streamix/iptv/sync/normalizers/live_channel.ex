defmodule Streamix.Iptv.Sync.Normalizers.LiveChannel do
  @moduledoc """
  Normalizes Xtream live stream payloads into channel attrs for sync upserts.
  """

  @doc """
  Builds live channel attrs from a raw Xtream stream payload.
  """
  def attrs(stream, provider_id, now) do
    %{
      stream_id: stream["stream_id"],
      name: stream["name"] || "Unknown",
      stream_icon: stream["stream_icon"],
      epg_channel_id: stream["epg_channel_id"],
      tv_archive: stream["tv_archive"] == 1,
      tv_archive_duration: stream["tv_archive_duration"],
      direct_source: stream["direct_source"],
      provider_id: provider_id,
      # No dead_since: panels keep listing channels whose stream is gone, so
      # clearing it on every sync (every few hours) brought a dead channel
      # straight back and viewers into a retry loop on it. The upsert only
      # replaces keys present here, so a 404 marker survives the sync and the
      # 24-hour recheck window in Channels decides when it is tried again.
      inserted_at: now,
      updated_at: now
    }
  end
end
