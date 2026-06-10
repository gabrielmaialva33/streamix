defmodule Streamix.Iptv.Assets do
  @moduledoc """
  Shared URL and presence helpers for content asset collections.

  Works on any struct holding a preloaded `assets` association (`Movie`,
  `Series`) whose entries expose `asset_type`, `position`, and `url`.
  """

  @spec backdrop_urls(struct() | term()) :: [String.t()]
  def backdrop_urls(content), do: urls(content, "backdrop")

  @spec image_urls(struct() | term()) :: [String.t()]
  def image_urls(content), do: urls(content, "image")

  @spec has_backdrops?(struct() | term()) :: boolean()
  def has_backdrops?(content), do: any?(content, "backdrop")

  @spec has_images?(struct() | term()) :: boolean()
  def has_images?(content), do: any?(content, "image")

  defp urls(%{assets: assets}, asset_type) when is_list(assets) do
    assets
    |> Enum.filter(&(&1.asset_type == asset_type))
    |> Enum.sort_by(& &1.position)
    |> Enum.map(& &1.url)
  end

  defp urls(_, _), do: []

  defp any?(%{assets: assets}, asset_type) when is_list(assets) do
    Enum.any?(assets, &(&1.asset_type == asset_type))
  end

  defp any?(_, _), do: false
end
