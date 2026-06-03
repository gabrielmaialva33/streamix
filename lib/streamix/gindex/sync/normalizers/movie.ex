defmodule Streamix.Gindex.Sync.Normalizers.Movie do
  @moduledoc """
  Normalizes parsed GIndex movie entries into database attrs.
  """

  def attrs(movie, provider, catalog_item_id, now) do
    %{
      provider_id: provider.id,
      stream_id: movie.stream_id,
      name: movie.name,
      title: movie.title,
      year: movie.year,
      container_extension: movie.container_extension,
      gindex_path: movie.gindex_path,
      catalog_item_id: catalog_item_id,
      inserted_at: now,
      updated_at: now
    }
  end
end
