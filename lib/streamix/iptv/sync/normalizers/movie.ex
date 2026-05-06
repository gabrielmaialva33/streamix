defmodule Streamix.Iptv.Sync.Normalizers.Movie do
  @moduledoc """
  Normalizes Xtream VOD stream payloads into movie attrs for sync upserts.
  """

  alias Streamix.Iptv.Sync.Helpers

  @doc """
  Builds movie attrs from a raw Xtream stream payload.
  """
  def attrs(stream, provider_id, now) do
    %{
      stream_id: stream["stream_id"],
      name: stream["name"] || "Unknown",
      title: stream["title"],
      year: Helpers.parse_year(stream["year"]),
      stream_icon: stream["stream_icon"],
      rating: Helpers.parse_decimal(stream["rating"]),
      plot: stream["plot"],
      container_extension: stream["container_extension"],
      duration_secs: stream["duration_secs"],
      tmdb_id: Helpers.to_string_or_nil(stream["tmdb_id"]),
      imdb_id: Helpers.to_string_or_nil(stream["imdb_id"]),
      youtube_trailer: stream["youtube_trailer"],
      provider_id: provider_id,
      inserted_at: now,
      updated_at: now
    }
  end
end
