defmodule Streamix.Gindex.Sync.Normalizers.Episode do
  @moduledoc """
  Normalizes parsed GIndex episode entries into the IPTV ingest contract.
  """

  def attrs(episode) do
    %{
      episode_id: episode.episode_id,
      episode_num: episode.episode_num,
      title: episode.title,
      name: episode.name,
      container_extension: episode.container_extension,
      gindex_path: episode.gindex_path
    }
  end
end
