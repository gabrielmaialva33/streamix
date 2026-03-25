defmodule StreamixWeb.Helpers.ImageProxy do
  @moduledoc """
  Helper for proxying external images through Cloudflare CDN.

  Replaces external image URLs (TMDB, imgmxa) with our Cloudflare-proxied
  domains for better caching, performance, and reliability.

  ## Netflix-style Image Optimization

  Uses appropriate TMDB sizes based on context:
  - thumbnail: w185 (~10-20KB) - for small cards in grids
  - card: w342 (~25-40KB) - for standard movie/series cards
  - detail: w500 (~50-80KB) - for detail pages and modals
  - hero: w1280 (~100-200KB) - for hero backgrounds
  - original: original - for full quality (rarely needed)
  """

  @image_cache_version "v2"

  # TMDB image sizes (Netflix uses 20-30KB for thumbnails)
  @tmdb_sizes %{
    # ~10-20KB - small grids
    thumbnail: "w185",
    # ~25-40KB - movie cards
    card: "w342",
    # ~50-80KB - detail pages
    detail: "w500",
    # ~100-200KB - hero backgrounds
    hero: "w1280",
    # ~60-100KB - backdrop images
    backdrop: "w780",
    # full quality
    original: "original"
  }

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
    # Normalize TMDB mirror domains to our proxy (only /t/p/ paths are TMDB)
    |> normalize_gstatic()
    |> String.replace("https://image.tmdb.org", "https://tmdb.mahina.cloud")
    |> String.replace("https://imgmxa.net", "https://imgmxa.mahina.cloud")
    |> String.replace("http://imgmxa.net", "https://imgmxa.mahina.cloud")
    # Provider logos via our nginx proxy (port 8084)
    |> proxy_provider_logos()
    |> add_cache_buster()
  end

  @doc """
  Proxies an image URL without cache buster (for og:image etc).
  """
  def proxy_raw(nil), do: nil
  def proxy_raw(""), do: nil

  def proxy_raw(url) when is_binary(url) do
    url
    |> normalize_gstatic()
    |> String.replace("https://image.tmdb.org", "https://tmdb.mahina.cloud")
    |> String.replace("https://imgmxa.net", "https://imgmxa.mahina.cloud")
    |> String.replace("http://imgmxa.net", "https://imgmxa.mahina.cloud")
    |> proxy_provider_logos()
  end

  # gstaticontent URLs with /t/p/ are TMDB mirrors, others go through stream proxy
  defp normalize_gstatic(url) do
    cond do
      String.match?(
        url,
        ~r{https?://(?:file\.)?gstaticontent\.com/+.*/t/p/|https?://(?:file\.)?gstaticontent\.com/+t/p/}
      ) ->
        url
        |> String.replace(
          ~r{https?://(?:file\.)?gstaticontent\.com/+},
          "https://tmdb.mahina.cloud/"
        )
        |> String.replace("//t/p/", "/t/p/")

      String.match?(url, ~r{https?://(?:file\.)?gstaticontent\.com/}) ->
        http_url = String.replace(url, "https://", "http://")
        "https://stream.mahina.cloud/proxy?url=#{URI.encode_www_form(http_url)}"

      true ->
        url
    end
  end

  @provider_logo_domains ["cb.chokitecnologia.com", "www.acstatic.co", "fanc.tmsimg.com"]

  defp proxy_provider_logos(url) do
    if Enum.any?(@provider_logo_domains, &String.contains?(url, &1)) do
      # Force HTTP for provider logos (HTTPS certs are invalid)
      http_url = String.replace(url, "https://", "http://")
      "https://stream.mahina.cloud/proxy?url=#{URI.encode_www_form(http_url)}"
    else
      url
    end
  end

  defp add_cache_buster(url) do
    if String.contains?(url, "?") do
      "#{url}&_v=#{@image_cache_version}"
    else
      "#{url}?_v=#{@image_cache_version}"
    end
  end

  @doc """
  Returns optimized image URL for thumbnails (smallest, ~10-20KB).
  Best for: small cards in grids, "continue watching" row.

  ## Examples

      iex> thumbnail("https://image.tmdb.org/t/p/w500/abc.jpg")
      "https://tmdb.mahina.cloud/t/p/w185/abc.jpg?_v=v2"
  """
  def thumbnail(nil), do: nil
  def thumbnail(""), do: nil
  def thumbnail(url), do: url |> resize(:thumbnail) |> proxy()

  @doc """
  Returns optimized image URL for cards (~25-40KB).
  Best for: movie/series cards in browse pages.
  """
  def card(nil), do: nil
  def card(""), do: nil
  def card(url), do: url |> resize(:card) |> proxy()

  @doc """
  Returns optimized image URL for detail pages (~50-80KB).
  Best for: movie detail modals, expanded hover views.
  """
  def detail(nil), do: nil
  def detail(""), do: nil
  def detail(url), do: url |> resize(:detail) |> proxy()

  @doc """
  Returns optimized image URL for hero/backdrop (~100-200KB).
  Best for: homepage hero, full-width backgrounds.
  """
  def hero(nil), do: nil
  def hero(""), do: nil
  def hero(url), do: url |> resize(:hero) |> proxy()

  @doc """
  Returns optimized backdrop image URL (~60-100KB).
  """
  def backdrop(nil), do: nil
  def backdrop(""), do: nil
  def backdrop(url), do: url |> resize(:backdrop) |> proxy()

  @doc """
  Resizes a TMDB image URL to a specific size.
  Supports: :thumbnail, :card, :detail, :hero, :backdrop, :original

  ## Examples

      iex> resize("https://tmdb.mahina.cloud/t/p/w500/abc.jpg", :thumbnail)
      "https://tmdb.mahina.cloud/t/p/w185/abc.jpg"
  """
  def resize(nil, _size), do: nil
  def resize("", _size), do: nil

  def resize(url, size) when is_binary(url) and is_atom(size) do
    target_size = Map.get(@tmdb_sizes, size, @tmdb_sizes.card)

    # Replace TMDB size in URL (handles both original and proxied URLs)
    # Also handles gstaticontent-style sizes like w600_and_h900_bestv2
    url
    |> String.replace(~r{/t/p/(w\d+(?:_and_h\d+_bestv2)?|original)/}, "/t/p/#{target_size}/")
    |> String.replace(
      ~r{image\.tmdb\.org/t/p/(w\d+|original)/},
      "image.tmdb.org/t/p/#{target_size}/"
    )
  end

  def resize(url, _size), do: url

  @doc """
  Returns srcset for responsive images (Netflix progressive loading).

  ## Examples

      iex> srcset("/abc.jpg")
      "https://tmdb.mahina.cloud/t/p/w185/abc.jpg 185w, https://tmdb.mahina.cloud/t/p/w342/abc.jpg 342w, https://tmdb.mahina.cloud/t/p/w500/abc.jpg 500w"
  """
  def srcset(nil), do: nil
  def srcset(""), do: nil

  def srcset(path) when is_binary(path) do
    # Extract just the path if full URL
    clean_path = extract_tmdb_path(path)

    if clean_path do
      [
        {"w185", "185w"},
        {"w342", "342w"},
        {"w500", "500w"}
      ]
      |> Enum.map(fn {size, width} ->
        "https://tmdb.mahina.cloud/t/p/#{size}#{clean_path} #{width}"
      end)
      |> Enum.join(", ")
    end
  end

  defp extract_tmdb_path(url) do
    # Match TMDB path pattern: /abc123.jpg
    case Regex.run(~r{/t/p/(?:w\d+|original)(/[^?]+)}, url) do
      [_, path] ->
        path

      _ ->
        # Maybe it's just a path
        if String.starts_with?(url, "/") and String.ends_with?(url, ".jpg"),
          do: url,
          else: nil
    end
  end
end
