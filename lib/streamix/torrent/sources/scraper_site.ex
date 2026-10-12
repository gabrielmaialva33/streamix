defmodule Streamix.Torrent.Sources.ScraperSite do
  @moduledoc """
  Resolved configuration of one HTML torrent site and its mirrors.

  A source module (e.g. `Streamix.Torrent.Sources.GratisTorrent`) owns the
  site's defaults — mirror list, paths and selectors verified against the
  live markup. Deployments override them under `:streamix,
  :torrent_scrapers` keyed by slug; `nil` values are ignored so an unset
  environment variable never blanks a default:

      config :streamix, :torrent_scrapers,
        comandotorrent: [
          # Ordered mirror list. Replaces the defaults entirely.
          base_urls: ["https://comando1.com", "https://comandotorrents.to"],
          # Legacy single URL: tried first, then the default mirrors.
          base_url: "https://comando.la",
          post_link_selector: "article h2.entry-title a",
          page_path: "/page/{page}/",
          search_path: "/?s={query}",
          max_pages: 5,
          enabled: true
        ]

  Every mirror carries the full parsing profile. A mirror whose host has a
  profile in the source's `:mirror_profiles` (a different theme serving the
  same catalog) uses that profile instead of the site-level selectors.

  The first configured base URL is the site's *canonical* base: post URLs
  found on any mirror are re-keyed onto it when the mirror shares the
  canonical URL layout, so switching mirrors does not duplicate movies.
  """

  @profile_keys ~w(list_path page_path search_path post_link_selector content_selector
                   title_selector original_title_selector imdb_selector poster_selector
                   page_marker_selector max_posts_per_page same_paths)a

  @default_profile [
    list_path: "/",
    page_path: "/page/{page}/",
    search_path: "/?s={query}",
    post_link_selector: "article h2 a, .title a, h2.entry-title a",
    content_selector: nil,
    title_selector: "h1",
    original_title_selector: nil,
    imdb_selector: "a[href*='imdb.com']",
    poster_selector: "article img, .entry-content img",
    page_marker_selector: nil,
    max_posts_per_page: 15,
    same_paths: true
  ]

  @default_max_pages 5
  @default_min_interval_ms 1_500
  @default_max_search_candidates 3

  @type mirror :: %{
          required(:base_url) => String.t(),
          required(:host) => String.t(),
          optional(atom()) => term()
        }

  @type t :: %__MODULE__{
          slug: String.t(),
          enabled: boolean(),
          mirrors: [mirror()],
          canonical_base: String.t() | nil,
          max_pages: pos_integer(),
          min_interval_ms: non_neg_integer(),
          max_search_candidates: pos_integer()
        }

  defstruct slug: nil,
            enabled: false,
            mirrors: [],
            canonical_base: nil,
            max_pages: @default_max_pages,
            min_interval_ms: @default_min_interval_ms,
            max_search_candidates: @default_max_search_candidates

  @doc """
  Builds the site from source defaults merged with the application config
  for `slug`.
  """
  @spec build(String.t() | atom(), keyword()) :: t()
  def build(slug, defaults \\ []) do
    overrides = slug |> app_overrides() |> reject_nil()
    defaults = reject_nil(defaults)

    profile =
      @default_profile
      |> Keyword.merge(Keyword.take(defaults, @profile_keys))
      |> Keyword.merge(Keyword.take(overrides, @profile_keys))

    base_urls = resolve_base_urls(Keyword.get(defaults, :base_urls, []), overrides)
    mirror_profiles = Keyword.get(defaults, :mirror_profiles, %{})

    mirrors =
      Enum.map(base_urls, fn base_url ->
        host = host(base_url)

        profile
        |> Keyword.merge(Map.get(mirror_profiles, host, []))
        |> Map.new()
        |> Map.merge(%{base_url: base_url, host: host})
      end)

    %__MODULE__{
      slug: to_string(slug),
      enabled: Keyword.get(overrides, :enabled, true) != false and mirrors != [],
      mirrors: mirrors,
      canonical_base: List.first(base_urls),
      max_pages: positive(overrides[:max_pages] || defaults[:max_pages], @default_max_pages),
      min_interval_ms: min_interval_ms(overrides),
      max_search_candidates:
        positive(
          overrides[:max_search_candidates] || defaults[:max_search_candidates],
          @default_max_search_candidates
        )
    }
  end

  @doc "Whether the site has at least one mirror and is not switched off."
  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{enabled: enabled}), do: enabled

  @doc "Absolute listing URL for `page` on `mirror`."
  @spec listing_url(mirror(), pos_integer()) :: String.t()
  def listing_url(mirror, page) when page <= 1, do: mirror.base_url <> mirror.list_path

  def listing_url(mirror, page) do
    prefix =
      if mirror.list_path in ["", "/"], do: "", else: String.trim_trailing(mirror.list_path, "/")

    mirror.base_url <>
      prefix <> String.replace(mirror.page_path, "{page}", Integer.to_string(page))
  end

  @doc "Absolute search URL for `query` on `mirror`."
  @spec search_url(mirror(), String.t()) :: String.t()
  def search_url(mirror, query) do
    mirror.base_url <> String.replace(mirror.search_path, "{query}", URI.encode_www_form(query))
  end

  @doc "The mirror that serves `url` (by host), or the first mirror."
  @spec mirror_for(t(), String.t()) :: mirror() | nil
  def mirror_for(%__MODULE__{mirrors: mirrors}, url) do
    url_host = host(url)
    Enum.find(mirrors, List.first(mirrors), &(&1.host == url_host))
  end

  @doc """
  Stable identity for a post URL: the same path on the canonical base when
  the serving mirror shares the canonical URL layout, otherwise the URL as
  served.
  """
  @spec canonical_url(t(), String.t()) :: String.t()
  def canonical_url(%__MODULE__{canonical_base: nil}, url), do: url

  def canonical_url(%__MODULE__{} = site, url) do
    mirror = mirror_for(site, url)

    with true <- mirror != nil and mirror.same_paths,
         %URI{path: path} when is_binary(path) <- URI.parse(url) do
      site.canonical_base <> path
    else
      _ -> url
    end
  end

  @doc ~s|Lower-cased host of a URL without a leading "www.", or "".|
  @spec host(String.t()) :: String.t()
  def host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        host |> String.downcase() |> String.replace_prefix("www.", "")

      _ ->
        ""
    end
  end

  defp resolve_base_urls(defaults, overrides) do
    urls =
      cond do
        valid_list?(overrides[:base_urls]) -> overrides[:base_urls]
        is_binary(overrides[:base_url]) -> [overrides[:base_url] | List.wrap(defaults)]
        true -> List.wrap(defaults)
      end

    urls
    |> Enum.map(&normalize_base/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp valid_list?(list), do: is_list(list) and Enum.any?(list, &is_binary/1)

  defp normalize_base(url) when is_binary(url) do
    trimmed = url |> String.trim() |> String.trim_trailing("/")

    case URI.parse(trimmed) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        trimmed

      _ ->
        nil
    end
  end

  defp normalize_base(_url), do: nil

  defp min_interval_ms(overrides) do
    case overrides[:min_interval_ms] ||
           Application.get_env(:streamix, :torrent_scraper_min_interval_ms) do
      value when is_integer(value) and value >= 0 -> value
      _ -> @default_min_interval_ms
    end
  end

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp app_overrides(slug) do
    config = Application.get_env(:streamix, :torrent_scrapers, [])
    key = slug_key(slug)

    cond do
      is_list(config) and is_atom(key) -> Keyword.get(config, key, [])
      is_map(config) -> Map.get(config, key) || Map.get(config, to_string(slug)) || []
      true -> []
    end
    |> List.wrap()
  end

  defp slug_key(slug) when is_atom(slug), do: slug

  defp slug_key(slug) when is_binary(slug) do
    String.to_existing_atom(slug)
  rescue
    ArgumentError -> nil
  end

  defp reject_nil(keyword) when is_list(keyword) do
    Enum.reject(keyword, fn {_key, value} -> is_nil(value) end)
  end

  defp reject_nil(_other), do: []
end
