defmodule Streamix.Torrent.Sources.HtmlScraper do
  @moduledoc """
  Generic HTML scraper for BR torrent sites (ComandoTorrent,
  GratisTorrent, ...).

  These sites share a shape: a paginated listing of posts, each post a
  page with one or more `magnet:` links plus a release title carrying
  year/quality/audio. This module walks that shape with the selectors of a
  `Streamix.Torrent.Sources.ScraperSite`, so a layout change is a config
  tweak, not a code edit.

  Two entry points:

    * `fetch_listing/2` — one listing page per call (the nightly crawl,
      capped at the site's `max_pages` newest pages).
    * `search/3` — targeted lookup of one wanted title through the site's
      own search, fetching only the few posts whose snippet matches.

  ## Honest failures

  A page that cannot be read is never reported as an empty success:

    * `{:blocked, details}` — challenge, interstitial or 403 (see
      `Streamix.Torrent.Sources.ScraperHttp`);
    * `{:layout_changed, details}` — the page was fetched but the post
      selector (or, on a whole page of posts, the magnet selector) matched
      nothing;
    * `{:rate_limited, details}`, `{:http_error, details}`,
      `{:transport_error, details}`.

  Mirrors are tried in order; the error returned when all of them fail
  carries every attempt under `:attempts`. Without any configured mirror
  the site reports a disabled empty page so the orchestrator can tell
  "not configured" apart from "configured but broken".
  """

  require Logger

  alias Streamix.Torrent.{Magnet, Matching}
  alias Streamix.Torrent.Sources.{Helpers, PostParser, ReleaseInfo, ScraperHttp, ScraperSite}

  @failure_kinds [
    :layout_changed,
    :blocked,
    :rate_limited,
    :http_error,
    :not_found,
    :transport_error
  ]

  # Errors that end a page/search at once: continuing would only hammer a
  # site that is throttling or refusing us.
  @abort_kinds [:blocked, :rate_limited]

  @doc """
  Scrapes one listing page of `site` (or of the slug's configured site).

  Returns `{:ok, items, meta}` with `meta.next_page` (nil after the site's
  `max_pages`), `meta.mirror` (the base URL that answered), `meta.skipped`
  (series/bundles not ingested as movies) and `meta.failed_posts`.
  """
  @spec fetch_listing(ScraperSite.t() | String.t() | atom(), keyword()) ::
          {:ok, [map()], map()} | {:error, term()}
  def fetch_listing(site_or_slug, opts \\ [])

  def fetch_listing(%ScraperSite{} = site, opts) do
    page = Keyword.get(opts, :page, 1)

    if ScraperSite.enabled?(site) do
      case listing_entries(site, page) do
        {:ok, mirror, url, entries} -> scrape_entries(site, mirror, url, entries, page)
        :end_of_listing -> {:ok, [], %{next_page: nil, end_of_listing?: true}}
        {:error, _reason} = error -> error
      end
    else
      {:ok, [], %{next_page: nil, disabled?: true}}
    end
  end

  def fetch_listing(slug, opts) when is_binary(slug) or is_atom(slug),
    do: fetch_listing(ScraperSite.build(slug), opts)

  @doc """
  Looks a wanted movie up through the site's search.

  Only search results whose snippet passes `Streamix.Torrent.Matching.prefilter/2`
  are opened (at most `site.max_search_candidates`). Returns the scraped
  candidate items; deciding which of them *is* the wanted movie is left to
  `Streamix.Torrent.Matching.match/2`.
  """
  @spec search(ScraperSite.t(), Matching.wanted(), keyword()) ::
          {:ok, [map()], map()} | {:error, term()}
  def search(%ScraperSite{} = site, wanted, _opts \\ []) do
    query =
      [Map.get(wanted, :title), Map.get(wanted, :original_title)]
      |> Enum.find(&Matching.searchable?/1)

    cond do
      not ScraperSite.enabled?(site) ->
        {:ok, [], %{disabled?: true}}

      is_nil(query) ->
        {:ok, [], %{unsearchable?: true}}

      true ->
        with {:ok, mirror, url, entries} <- search_entries(site, Matching.search_query(query)) do
          candidates =
            entries
            |> Enum.filter(&(not skippable?(&1) and Matching.prefilter(wanted, snippet(&1))))
            |> Enum.take(site.max_search_candidates)

          fetch_candidates(site, candidates, %{
            mirror: mirror.base_url,
            search_url: url,
            results: length(entries)
          })
        end
    end
  end

  @doc """
  Fetches and parses one post. `{:skip, reason}` for posts that are not a
  single movie with magnets (`:series`, `:bundle`, `:no_magnets`).
  """
  @spec fetch_post(ScraperSite.t(), String.t()) ::
          {:ok, map()} | {:skip, atom()} | {:error, term()}
  def fetch_post(%ScraperSite{} = site, url) do
    mirror = ScraperSite.mirror_for(site, url)

    with {:ok, body} <- ScraperHttp.get(url, min_interval_ms: site.min_interval_ms),
         {:ok, doc} <- parse_document(body, url) do
      build_item(site, url, PostParser.parse(doc, mirror))
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

  @doc """
  The failure state of a scraper error: `:blocked`, `:layout_changed`,
  `:rate_limited`, `:http_error`, `:not_found`, `:transport_error`, or
  `:error` for anything else.
  """
  @spec failure_kind(term()) :: atom()
  def failure_kind({kind, details}) when kind in @failure_kinds and is_map(details), do: kind
  def failure_kind(_reason), do: :error

  # --- listing --------------------------------------------------------------

  defp listing_entries(site, page) do
    try_mirrors(site, fn mirror ->
      url = ScraperSite.listing_url(mirror, page)

      case fetch_document(site, url) do
        {:ok, doc} ->
          entries_or_layout_error(doc, mirror, url, :listing)

        # WordPress answers 404 past the last page: the listing ended.
        {:error, {:not_found, _details}} when page > 1 ->
          :end_of_listing

        {:error, _reason} = error ->
          error
      end
    end)
  end

  # A listing page must show posts. A search page may legitimately show
  # none, as long as it is still the site's page (its search box is there).
  defp entries_or_layout_error(doc, mirror, url, what) do
    entries = post_entries(doc, mirror)

    if entries == [] and (what == :listing or not marker_present?(doc, mirror)),
      do: {:error, layout_changed(url, mirror, doc, what)},
      else: {:ok, mirror, url, entries}
  end

  defp scrape_entries(site, mirror, url, entries, page) do
    {skipped, to_fetch} = Enum.split_with(entries, &skippable?/1)

    case fetch_posts(site, to_fetch) do
      {:abort, reason} ->
        {:error, reason}

      {:done, results} ->
        meta = %{
          next_page: if(page < site.max_pages, do: page + 1),
          mirror: mirror.base_url,
          skipped: length(skipped) + Enum.count(results, &match?({:skip, _}, &1)),
          failed_posts: Enum.count(results, &match?({:error, _}, &1))
        }

        page_result(site, url, to_fetch, results, meta)
    end
  end

  # Items win. A page that produced none is a failure when its posts failed
  # to load, or when every post lost its magnets (the post layout changed);
  # a page of nothing but skipped seasons/bundles is a legitimate empty page.
  defp page_result(site, url, to_fetch, results, meta) do
    items = for {:ok, item} <- results, do: item
    errors = for {:error, reason} <- results, do: reason
    no_magnets = Enum.count(results, &(&1 == {:skip, :no_magnets}))

    cond do
      items == [] and errors != [] ->
        {:error, with_context(hd(errors), %{listing_url: url, failed_posts: length(errors)})}

      to_fetch != [] and no_magnets == length(to_fetch) ->
        {:error,
         {:layout_changed,
          %{url: url, what: :magnets, selector: "a[href^='magnet:']", posts: no_magnets}}}

      true ->
        maybe_log_partial(site, url, meta)
        {:ok, items, meta}
    end
  end

  defp maybe_log_partial(_site, _url, %{failed_posts: 0}), do: :ok

  defp maybe_log_partial(site, url, meta) do
    Logger.warning(
      "[Torrent.HtmlScraper] #{site.slug} #{url}: #{meta.failed_posts} post(s) failed to load"
    )
  end

  # --- search ---------------------------------------------------------------

  defp search_entries(site, query) do
    try_mirrors(site, fn mirror ->
      url = ScraperSite.search_url(mirror, query)

      with {:ok, doc} <- fetch_document(site, url) do
        entries_or_layout_error(doc, mirror, url, :search)
      end
    end)
  end

  defp fetch_candidates(site, candidates, meta) do
    case fetch_posts(site, candidates) do
      {:abort, reason} ->
        {:error, reason}

      {:done, results} ->
        items = for {:ok, item} <- results, do: item
        errors = for {:error, reason} <- results, do: reason
        {:ok, items, Map.merge(meta, %{candidates: length(candidates), failed_posts: errors})}
    end
  end

  # A search page that still shows the site's own search box but no results
  # is a genuine "nothing found". Without a configured marker we cannot
  # tell, and a miss is the safe reading.
  defp marker_present?(doc, mirror) do
    case Map.get(mirror, :page_marker_selector) do
      nil -> true
      selector -> Floki.find(doc, selector) != []
    end
  end

  # --- posts ----------------------------------------------------------------

  defp fetch_posts(site, entries) do
    entries
    |> Enum.reduce_while({:done, []}, fn entry, {:done, acc} ->
      site |> fetch_post(entry.url) |> collect_post(entry, acc)
    end)
    |> case do
      {:done, results} -> {:done, Enum.reverse(results)}
      abort -> abort
    end
  end

  defp collect_post({:error, reason} = error, entry, acc) do
    if failure_kind(reason) in @abort_kinds,
      do: {:halt, {:abort, with_context(reason, %{post_url: entry.url})}},
      else: {:cont, {:done, [error | acc]}}
  end

  defp collect_post(result, _entry, acc), do: {:cont, {:done, [result | acc]}}

  defp build_item(site, url, post) do
    raw_title = post.raw_title

    cond do
      ReleaseInfo.series?(raw_title) ->
        {:skip, :series}

      ReleaseInfo.bundle?(raw_title) ->
        {:skip, :bundle}

      true ->
        case torrents(site, raw_title, post.magnets) do
          [] -> {:skip, :no_magnets}
          torrents -> {:ok, item(site, url, post, torrents)}
        end
    end
  end

  defp item(site, url, post, torrents) do
    %{
      external_id: ScraperSite.canonical_url(site, url),
      source_url: url,
      title: blankless(ReleaseInfo.extract_title(post.raw_title)) || post.raw_title,
      original_title: post.original_title,
      year: post.year,
      imdb_id: post.imdb_id,
      tmdb_id: nil,
      poster_url: post.poster_url,
      backdrop_url: nil,
      plot: nil,
      rating: nil,
      runtime_minutes: nil,
      genres: [],
      torrents: torrents
    }
  end

  defp torrents(site, raw_title, magnets) do
    magnets
    |> Enum.filter(&is_binary(&1.info_hash))
    |> Enum.map(fn magnet ->
      local = magnet.label <> " " <> (magnet.display_name || "")
      release = ReleaseInfo.for_magnet(raw_title, local, magnet.section)

      %{
        info_hash: magnet.info_hash,
        magnet_uri: Magnet.normalize(magnet.uri),
        source_slug: site.slug,
        quality: release.quality,
        codec: nil,
        audio_track: release.audio_track,
        release_flags: release.flags,
        container: nil,
        size_bytes: Helpers.parse_size_bytes(magnet.label),
        seeders: 0,
        leechers: 0
      }
    end)
  end

  # --- listing/search entries ------------------------------------------------

  defp post_entries(doc, mirror) do
    doc
    |> Floki.find(mirror.post_link_selector)
    |> Enum.flat_map(&entry(&1, mirror))
    |> Enum.uniq_by(& &1.url)
    |> Enum.take(mirror.max_posts_per_page)
  end

  defp entry({_tag, attrs, _children} = node, mirror) do
    with href when is_binary(href) and href != "" <- attr(attrs, "href"),
         url = absolute(mirror.base_url, href),
         true <- ScraperSite.host(url) == mirror.host do
      text =
        [Floki.text([node]), attr(attrs, "title")] ++
          Floki.attribute(Floki.find([node], "[data-title]"), "data-title")

      [%{url: url, text: text |> Enum.reject(&is_nil/1) |> Enum.join(" ") |> squish()}]
    else
      _ -> []
    end
  end

  defp entry(_node, _mirror), do: []

  defp skippable?(entry) do
    words = snippet(entry)
    ReleaseInfo.series?(words) or ReleaseInfo.bundle?(words)
  end

  defp snippet(entry) do
    path = URI.parse(entry.url).path || ""
    path <> " " <> entry.text
  end

  # --- mirrors ----------------------------------------------------------------

  defp try_mirrors(site, fun) do
    site
    |> ordered_mirrors()
    |> Enum.reduce_while([], fn mirror, failures ->
      case fun.(mirror) do
        {:error, reason} ->
          {:cont, [{mirror.base_url, reason} | failures]}

        result ->
          remember_mirror(site, mirror)
          {:halt, result}
      end
    end)
    |> case do
      failures when is_list(failures) -> {:error, combine_failures(Enum.reverse(failures))}
      result -> result
    end
  end

  # The mirror that answered last is tried first on the next call from the
  # same job, so a dead primary costs one request per job, not per page.
  defp ordered_mirrors(site) do
    case Process.get({__MODULE__, :active_mirror, site.slug}) do
      nil ->
        site.mirrors

      base_url ->
        {active, rest} = Enum.split_with(site.mirrors, &(&1.base_url == base_url))
        active ++ rest
    end
  end

  defp remember_mirror(site, mirror) do
    Process.put({__MODULE__, :active_mirror, site.slug}, mirror.base_url)
  end

  defp combine_failures([]), do: {:transport_error, %{url: nil, reason: :no_mirrors}}

  defp combine_failures(failures) do
    attempts =
      Enum.map(failures, fn {base_url, reason} ->
        %{base_url: base_url, kind: failure_kind(reason), status: status_of(reason)}
      end)

    kind =
      Enum.find(@failure_kinds, :error, fn kind ->
        Enum.any?(failures, fn {_base, reason} -> failure_kind(reason) == kind end)
      end)

    {_base, reason} =
      Enum.find(failures, hd(failures), fn {_base, reason} -> failure_kind(reason) == kind end)

    with_context(reason, %{attempts: attempts})
  end

  defp status_of({_kind, %{status: status}}), do: status
  defp status_of(_reason), do: nil

  # --- helpers ----------------------------------------------------------------

  defp fetch_document(site, url) do
    with {:ok, body} <- ScraperHttp.get(url, min_interval_ms: site.min_interval_ms) do
      parse_document(body, url)
    end
  end

  defp parse_document(body, url) do
    case Floki.parse_document(body) do
      {:ok, doc} -> {:ok, doc}
      {:error, reason} -> {:error, {:layout_changed, %{url: url, reason: {:unparseable, reason}}}}
    end
  end

  defp layout_changed(url, mirror, doc, what) do
    {:layout_changed,
     %{
       url: url,
       what: what,
       selector: mirror.post_link_selector,
       page_marker?: marker_present?(doc, mirror)
     }}
  end

  defp with_context({kind, details}, context) when is_map(details),
    do: {kind, Map.merge(details, context)}

  defp with_context(reason, _context), do: reason

  defp absolute(base_url, href) do
    base_url |> URI.merge(href) |> URI.to_string()
  rescue
    _ -> href
  end

  defp attr(attrs, name) do
    Enum.find_value(attrs, fn
      {^name, value} -> value
      _ -> nil
    end)
  end

  defp squish(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp blankless(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      v -> v
    end
  end
end
