defmodule Streamix.PublicUrls do
  @moduledoc """
  The public origins of the edge proxies in front of Streamix.

  Each is set from the environment in `config/runtime.exs`; the fallback for
  an unset value is defined here once, instead of beside every reader.
  """

  @doc "Origin of the stream proxy (`STREAM_PROXY_URL`)."
  @spec stream_proxy() :: String.t()
  def stream_proxy, do: get(:stream_proxy_url, "https://source.mahina.fun")

  @doc "Origin of the TMDB image proxy (`TMDB_PROXY_URL`)."
  @spec tmdb_proxy() :: String.t()
  def tmdb_proxy, do: get(:tmdb_proxy_url, "https://tmdb.mahina.fun")

  @doc "Origin of the imgmxa image proxy (`IMGMXA_PROXY_URL`)."
  @spec imgmxa_proxy() :: String.t()
  def imgmxa_proxy, do: get(:imgmxa_proxy_url, "https://imgmxa.mahina.fun")

  @doc "Origin of the generic image resize proxy (`IMAGE_PROXY_URL`)."
  @spec image_proxy() :: String.t()
  def image_proxy, do: get(:image_proxy_url, "https://img.mahina.fun")

  defp get(key, default), do: Application.get_env(:streamix, key) || default
end
