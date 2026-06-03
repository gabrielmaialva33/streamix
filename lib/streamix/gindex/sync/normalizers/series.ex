defmodule Streamix.Gindex.Sync.Normalizers.Series do
  @moduledoc """
  Normalizes parsed GIndex series/anime entries into schema attrs.
  """

  def attrs(data, provider) do
    %{
      provider_id: provider.id,
      series_id: data.series_id,
      name: data.name,
      title: data.title,
      year: data.year,
      gindex_path: data.gindex_path
    }
  end
end
