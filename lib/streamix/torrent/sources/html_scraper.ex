defmodule Streamix.Torrent.Sources.HtmlScraper do
  @moduledoc """
  Generic HTML scraper for BR WordPress torrent sites (ComandoTorrent,
  GratisTorrent, ...).

  These sites share a shape: a paginated listing of posts, each post a
  page with one or more `magnet:` links plus a release title carrying
  year/quality/audio. This module walks that shape with configurable
  selectors so a site layout change is a config tweak, not a code edit.

  Per-site config lives under `:streamix, :torrent_scrapers` keyed by
  slug:

      config :streamix, :torrent_scrapers,
        comandotorrent: [
          base_url: "https://example.tld",
          list_path: "/",           # "/page/2/" appended for pagination
          post_link_selector: "article h2 a, .post .title a",
          max_posts_per_page: 15
        ]

  Returns `{:ok, listing_items, meta}` like every `Source`. Without a
  configured `base_url` it returns an empty disabled page so the
  orchestrator skips it cleanly.
  """

  require Logger

  alias Streamix.Torrent.Magnet
  alias Streamix.Torrent.Sources.ReleaseInfo

  @headers [
    {"user-agent",
     "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"},
    {"accept", "text/html,application/xhtml+xml"},
    {"accept-language", "pt-BR,pt;q=0.9"}
  ]

  @timeout :timer.seconds(20)
  @default_max_posts 15
  @inter_post_sleep_ms 400

  @doc """
  Scrapes one listing page for a configured site slug.

  `opts[:page]` selects the page; each post page is fetched (politely,
  with a small delay) to harvest its magnets.
  """
  @spec fetch_listing(atom() | String.t(), keyword()) ::
          {:ok, [map()], map()} | {:error, term()}
  def fetch_listing(slug, opts \\ []) do
    config = config(slug)

    case config[:base_url] do
      url when is_binary(url) and url != "" -> do_fetch(slug, config, opts)
      _ -> {:ok, [], %{next_page: nil, disabled?: true}}
    end
  end

  defp do_fetch(slug, config, opts) do
    page = Keyword.get(opts, :page, 1)

    with {:ok, html} <- get(listing_url(config, page)),
         {:ok, doc} <- Floki.parse_document(html) do
      post_urls =
        doc
        |> Floki.find(config[:post_link_selector] || "article h2 a, .title a, h2 a")
        |> Floki.attribute("href")
        |> Enum.uniq()
        |> Enum.reject(&(&1 == "" or is_nil(&1)))
        |> Enum.take(config[:max_posts_per_page] || @default_max_posts)

      items =
        post_urls
        |> Enum.map(&scrape_post(slug, &1))
        |> Enum.reject(&is_nil/1)

      {:ok, items, %{next_page: next_page(post_urls, page)}}
    end
  end

  # A post page: pull the title and every magnet, fan the magnets into
  # one listing_item with N torrents.
  defp scrape_post(slug, url) do
    Process.sleep(@inter_post_sleep_ms)

    with {:ok, html} <- get(url),
         {:ok, doc} <- Floki.parse_document(html) do
      title = post_title(doc)
      magnets = magnet_links(doc)

      case magnets do
        [] ->
          nil

        magnets ->
          info = ReleaseInfo.parse(title)

          %{
            external_id: url,
            title: blankless(info.title) || title,
            year: info.year,
            imdb_id: nil,
            tmdb_id: nil,
            poster_url: post_poster(doc),
            backdrop_url: nil,
            plot: nil,
            rating: nil,
            runtime_minutes: nil,
            genres: [],
            torrents: Enum.map(magnets, &magnet_to_torrent(&1, slug, info))
          }
      end
    else
      _ -> nil
    end
  end

  @doc "Extracts every `magnet:` URI from a parsed document. Public for tests."
  @spec magnet_links(Floki.html_tree()) :: [String.t()]
  def magnet_links(doc) do
    doc
    |> Floki.find("a[href^='magnet:']")
    |> Floki.attribute("href")
    |> Enum.uniq()
  end

  defp magnet_to_torrent(magnet, slug, info) do
    %{
      info_hash: Magnet.info_hash(magnet),
      magnet_uri: magnet,
      source_slug: to_string(slug),
      quality: info.quality,
      codec: nil,
      audio_track: info.audio_track,
      container: nil,
      size_bytes: nil,
      seeders: 0,
      leechers: 0
    }
  end

  defp post_title(doc) do
    doc
    |> Floki.find("h1, .entry-title, .post-title, title")
    |> Floki.text()
    |> String.trim()
  end

  defp post_poster(doc) do
    doc
    |> Floki.find(".entry-content img, article img, .post img")
    |> Floki.attribute("src")
    |> List.first()
  end

  defp listing_url(config, page) do
    base = String.trim_trailing(config[:base_url], "/")
    path = config[:list_path] || "/"

    if page <= 1 do
      base <> path
    else
      base <> String.trim_trailing(path, "/") <> "/page/#{page}/"
    end
  end

  # We can't know the true last page without a "next" link, so advance
  # while a page still yields posts; the orchestrator's @max_pages caps it.
  defp next_page([], _page), do: nil
  defp next_page(_urls, page), do: page + 1

  defp get(url) do
    case Req.get(url,
           headers: @headers,
           receive_timeout: @timeout,
           finch: Streamix.Finch,
           decode_body: false,
           redirect: true
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        Logger.warning("[Torrent.HtmlScraper] #{url} -> HTTP #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("[Torrent.HtmlScraper] #{url} -> #{inspect(reason)}")
        {:error, {:transport_error, reason}}
    end
  end

  defp blankless(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      v -> v
    end
  end

  defp config(slug) do
    :streamix
    |> Application.get_env(:torrent_scrapers, [])
    |> Keyword.get(slug_atom(slug), [])
  end

  defp slug_atom(slug) when is_atom(slug), do: slug

  defp slug_atom(slug) when is_binary(slug) do
    String.to_existing_atom(slug)
  rescue
    ArgumentError -> :__unconfigured__
  end
end
