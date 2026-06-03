defmodule Streamix.Gindex.Sync.Normalizers.Season do
  @moduledoc """
  Normalizes parsed GIndex season entries into schema attrs.
  """

  def attrs(series, season_data) do
    %{
      series_id: series.id,
      season_number: season_data.season_number,
      name: season_data.name || "Season #{season_data.season_number}",
      episode_count: season_data.episode_count
    }
  end
end
