defmodule Streamix.Gindex.Sync.Normalizers.Movie do
  @moduledoc """
  Normalizes parsed GIndex movie entries into the IPTV ingest contract.
  """

  def attrs(movie) do
    %{
      stream_id: movie.stream_id,
      name: movie.name,
      title: movie.title,
      year: movie.year,
      container_extension: movie.container_extension,
      gindex_path: movie.gindex_path
    }
  end
end
