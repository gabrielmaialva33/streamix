defmodule Streamix.Iptv.Gindex.Sync.Normalizers.Episode do
  @moduledoc """
  Normalizes parsed GIndex episode entries into database attrs.
  """

  def attrs(episode, season, catalog_item_id, now) do
    %{
      season_id: season.id,
      episode_id: episode.episode_id,
      episode_num: episode.episode_num,
      title: episode.title,
      name: episode.name,
      container_extension: episode.container_extension,
      gindex_path: episode.gindex_path,
      catalog_item_id: catalog_item_id,
      inserted_at: now,
      updated_at: now
    }
  end
end
