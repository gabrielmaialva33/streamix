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

  defp tmdb_proxy_url,
    do: Application.get_env(:streamix, :tmdb_proxy_url, "https://tmdb.mahina.cloud")

  defp imgmxa_proxy_url,
    do: Application.get_env(:streamix, :imgmxa_proxy_url, "https://imgmxa.mahina.cloud")

  defp image_proxy_url,
    do: Application.get_env(:streamix, :image_proxy_url, "https://img.mahina.cloud")

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
    # Legacy DB rows can carry `http://image.tmdb.org//t/p/...` (HTTP +
    # double slash from old TMDB parser concat bug). Force HTTPS and
    # collapse adjacent slashes BEFORE the proxy replace so the URL
    # actually rewrites to our CDN instead of triggering Mixed Content
    # auto-upgrade warnings in the browser.
    |> normalize_legacy_tmdb()
    # Normalize TMDB mirror domains to our proxy (only /t/p/ paths are TMDB)
    |> normalize_gstatic()
    |> String.replace("https://image.tmdb.org", tmdb_proxy_url())
    |> String.replace("https://imgmxa.net", imgmxa_proxy_url())
    |> String.replace("http://imgmxa.net", imgmxa_proxy_url())
    # Provider logos via our nginx proxy (port 8084)
    |> proxy_provider_logos()
    |> proxy_insecure_external_image()
    |> add_cache_buster()
  end

  @doc """
  Proxies an image URL without cache buster (for og:image etc).
  """
  def proxy_raw(nil), do: nil
  def proxy_raw(""), do: nil

  def proxy_raw(url) when is_binary(url) do
    url
    |> normalize_legacy_tmdb()
    |> normalize_gstatic()
    |> String.replace("https://image.tmdb.org", tmdb_proxy_url())
    |> String.replace("https://imgmxa.net", imgmxa_proxy_url())
    |> String.replace("http://imgmxa.net", imgmxa_proxy_url())
    |> proxy_provider_logos()
    |> proxy_insecure_external_image()
  end

  # Upgrades any TMDB image URL to HTTPS and collapses accidental
  # double slashes between the host and the path. Only touches TMDB
  # URLs so we don't accidentally mangle provider logo paths.
  defp normalize_legacy_tmdb(url) do
    cond do
      String.starts_with?(url, "http://image.tmdb.org") ->
        url
        |> String.replace_prefix("http://", "https://")
        |> collapse_path_slashes("image.tmdb.org")

      String.starts_with?(url, "https://image.tmdb.org") ->
        collapse_path_slashes(url, "image.tmdb.org")

      true ->
        url
    end
  end

  defp collapse_path_slashes(url, host) do
    case String.split(url, host, parts: 2) do
      [prefix, rest] -> prefix <> host <> Regex.replace(~r"/{2,}", rest, "/")
      _ -> url
    end
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
          "#{tmdb_proxy_url()}/"
        )
        |> String.replace("//t/p/", "/t/p/")

      String.match?(url, ~r{https?://(?:file\.)?gstaticontent\.com/}) ->
        http_url = String.replace(url, "https://", "http://")
        "#{image_proxy_url()}/proxy?url=#{URI.encode_www_form(http_url)}"

      true ->
        url
    end
  end

  @provider_logo_domains ["cb.chokitecnologia.com", "www.acstatic.co", "fanc.tmsimg.com"]

  defp proxy_provider_logos(url) do
    if Enum.any?(@provider_logo_domains, &String.contains?(url, &1)) do
      # Force HTTP for provider logos (HTTPS certs are invalid)
      http_url = String.replace(url, "https://", "http://")
      "#{image_proxy_url()}/proxy?url=#{URI.encode_www_form(http_url)}"
    else
      url
    end
  end

  defp proxy_insecure_external_image("http://" <> _ = url) do
    if safe_external_http_image_url?(url) do
      "#{image_proxy_url()}/proxy?url=#{URI.encode_www_form(url)}"
    end
  end

  defp proxy_insecure_external_image(url), do: url

  defp safe_external_http_image_url?(url) do
    case URI.parse(url) do
      %URI{scheme: "http", host: host} when is_binary(host) ->
        public_host?(String.downcase(host))

      _ ->
        false
    end
  end

  defp public_host?(host) when host in ["localhost", "localhost.localdomain"], do: false
  defp public_host?(host) when byte_size(host) == 0, do: false

  defp public_host?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> public_ip?(address)
      {:error, :einval} -> not internal_hostname?(host)
    end
  end

  defp internal_hostname?(host) do
    String.ends_with?(host, [".localhost", ".local", ".internal"])
  end

  defp public_ip?({10, _, _, _}), do: false
  defp public_ip?({127, _, _, _}), do: false
  defp public_ip?({0, _, _, _}), do: false
  defp public_ip?({169, 254, _, _}), do: false
  defp public_ip?({172, second, _, _}) when second in 16..31, do: false
  defp public_ip?({192, 168, _, _}), do: false
  defp public_ip?({100, second, _, _}) when second in 64..127, do: false
  defp public_ip?({_, _, _, _}), do: true
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false

  defp public_ip?({first, _, _, _, _, _, _, _}) do
    cond do
      first == 0 -> false
      Bitwise.band(first, 0xFE00) == 0xFC00 -> false
      Bitwise.band(first, 0xFFC0) == 0xFE80 -> false
      true -> true
    end
  end

  defp add_cache_buster(nil), do: nil

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
  Returns the appropriate TMDB size atom for a given UI context.

  Lets callers pick the smallest acceptable variant without hard-coding
  `w342`/`w500` at every `<img>`. Values map to the atoms accepted by
  `resize/2` (so the full chain is `url |> resize(poster_size(ctx)) |> proxy()`,
  i.e. what `card/1`, `detail/1`, `hero/1`, `backdrop/1` already do).

  | Context          | Size atom   | TMDB width | Approx size |
  | :--------------- | :---------- | :--------- | :---------- |
  | `:carousel`      | `:card`     | w342       | 25-40KB     |
  | `:grid`          | `:card`     | w342       | 25-40KB     |
  | `:thumbnail`     | `:thumbnail`| w185       | 10-20KB     |
  | `:history`       | `:thumbnail`| w185       | 10-20KB     |
  | `:detail`        | `:detail`   | w500       | 50-80KB     |
  | `:hero_backdrop` | `:backdrop` | w780       | 60-100KB    |
  | `:hero`          | `:hero`     | w1280      | 100-200KB   |

  ## Examples

      iex> poster_size(:carousel)
      :card

      iex> poster_size(:hero_backdrop)
      :backdrop
  """
  @spec poster_size(atom()) :: atom()
  def poster_size(:carousel), do: :card
  def poster_size(:grid), do: :card
  def poster_size(:thumbnail), do: :thumbnail
  def poster_size(:history), do: :thumbnail
  def poster_size(:detail), do: :detail
  def poster_size(:hero_backdrop), do: :backdrop
  def poster_size(:hero), do: :hero
  def poster_size(_other), do: :card

  @doc """
  Convenience: resize + proxy in one call using a UI-context atom.

  Equivalent to `url |> resize(poster_size(ctx)) |> proxy()`.

  ## Examples

      iex> poster("https://image.tmdb.org/t/p/original/abc.jpg", :carousel)
      "https://tmdb.mahina.cloud/t/p/w342/abc.jpg?_v=v2"
  """
  @spec poster(String.t() | nil, atom()) :: String.t() | nil
  def poster(nil, _ctx), do: nil
  def poster("", _ctx), do: nil
  def poster(url, ctx), do: url |> resize(poster_size(ctx)) |> proxy()

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
      |> Enum.map_join(", ", fn {size, width} ->
        "#{tmdb_proxy_url()}/t/p/#{size}#{clean_path} #{width}"
      end)
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
