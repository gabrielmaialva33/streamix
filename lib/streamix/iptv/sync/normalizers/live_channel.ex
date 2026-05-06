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
      # If the upstream is listing the channel again, give it a fresh
      # chance at playback; the lazy 404 marker will re-flag it if still dead.
      dead_since: nil,
      inserted_at: now,
      updated_at: now
    }
  end
end
