defmodule StreamixWeb.Catalog.ImageProxy do
  @moduledoc """
  Catalog-facing image proxy wrapper.

  Thin layer over the lower-level `StreamixWeb.Helpers.ImageProxy` that
  keeps the catalog API's own cache-busting policy independent from the
  rest of the site. The catalog TV/mobile clients tolerate a `?_v=…`
  query string, and we want the freedom to bump the version here
  (e.g. after a CDN config change) without touching every `<img>` on the
  web UI.

  Accepts `nil`, `""`, a single URL, or a list of URLs and preserves the
  input cardinality so serializers can feed it raw struct fields.
  """

  # Bumping this forces the CDN to re-fetch images served to catalog
  # clients after a config change. Keep in sync with the previous
  # inline version in `CatalogController` unless you actually want a
  # cache bust.
  @image_cache_version "v2"

  def proxy(nil), do: nil
  def proxy(""), do: nil
  def proxy(urls) when is_list(urls), do: Enum.map(urls, &proxy/1)

  def proxy(url) when is_binary(url) do
    tmdb = Application.get_env(:streamix, :tmdb_proxy_url, "https://tmdb.mahina.fun")
    imgmxa = Application.get_env(:streamix, :imgmxa_proxy_url, "https://imgmxa.mahina.fun")

    url
    |> String.replace("https://image.tmdb.org", tmdb)
    |> String.replace("https://imgmxa.net", imgmxa)
    |> String.replace("http://imgmxa.net", imgmxa)
    |> add_cache_buster()
  end

  defp add_cache_buster(url) do
    if String.contains?(url, "?") do
      "#{url}&_v=#{@image_cache_version}"
    else
      "#{url}?_v=#{@image_cache_version}"
    end
  end
end
