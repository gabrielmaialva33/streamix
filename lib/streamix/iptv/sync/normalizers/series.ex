defmodule Streamix.Iptv.Sync.Normalizers.Series do
  @moduledoc """
  Normalizes Xtream series payloads into attrs for sync upserts.
  """

  alias Streamix.Iptv.Sync.Helpers

  @doc """
  Builds series attrs from a raw Xtream series payload.
  """
  def attrs(series, provider_id, now) do
    %{
      series_id: series["series_id"],
      name: series["name"] || "Unknown",
      title: series["title"],
      year: Helpers.parse_year(series["year"]),
      cover: series["cover"],
      rating: Helpers.parse_decimal(series["rating"]),
      plot: series["plot"],
      youtube_trailer: series["youtube_trailer"],
      tmdb_id: Helpers.to_string_or_nil(series["tmdb_id"]),
      provider_id: provider_id,
      inserted_at: now,
      updated_at: now
    }
  end
end
