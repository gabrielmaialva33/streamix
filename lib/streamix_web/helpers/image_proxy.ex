defmodule StreamixWeb.Helpers.ImageProxy do
  @moduledoc """
  Helper for proxying external images through Cloudflare CDN.

  Replaces external image URLs (TMDB, imgmxa) with our Cloudflare-proxied
  domains for better caching, performance, and reliability.
  """

  @image_cache_version "v2"

  @doc """
  Proxies an image URL through Cloudflare CDN.

  ## Examples

      iex> proxy("https://image.tmdb.org/t/p/w500/abc.jpg")
      "https://tmdb.mahina.cloud/t/p/w500/abc.jpg?_v=v2"

      iex> proxy(nil)
      nil
  """
  def proxy(nil), do: nil
  def proxy(""), do: nil
  def proxy(urls) when is_list(urls), do: Enum.map(urls, &proxy/1)

  def proxy(url) when is_binary(url) do
    url
    |> String.replace("https://image.tmdb.org", "https://tmdb.mahina.cloud")
    |> String.replace("https://imgmxa.net", "https://imgmxa.mahina.cloud")
    |> String.replace("http://imgmxa.net", "https://imgmxa.mahina.cloud")
    |> add_cache_buster()
  end

  @doc """
  Proxies an image URL without cache buster (for og:image etc).
  """
  def proxy_raw(nil), do: nil
  def proxy_raw(""), do: nil

  def proxy_raw(url) when is_binary(url) do
    url
    |> String.replace("https://image.tmdb.org", "https://tmdb.mahina.cloud")
    |> String.replace("https://imgmxa.net", "https://imgmxa.mahina.cloud")
    |> String.replace("http://imgmxa.net", "https://imgmxa.mahina.cloud")
  end

  defp add_cache_buster(url) do
    if String.contains?(url, "?") do
      "#{url}&_v=#{@image_cache_version}"
    else
      "#{url}?_v=#{@image_cache_version}"
    end
  end
end
