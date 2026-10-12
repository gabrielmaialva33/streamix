# BR torrent sources (ComandoTorrent, GratisTorrent)

Streamix scrapes two Brazilian torrent sites for dubbed and dual-audio movies:
`Streamix.Torrent.Sources.ComandoTorrent` and `Streamix.Torrent.Sources.GratisTorrent`. Both use the
generic `Streamix.Torrent.Sources.HtmlScraper`. They run with the torrent provider (`TORRENT_ENABLED=true`) in
two modes:

- **Nightly crawl.** `SyncTorrentProviderWorker` (04:00 UTC) runs one `SyncSourceWorker` per source. It reads the
  newest `max_pages` listing pages (default 5) and opens every post on them.
- **Targeted search.** This mode looks up a list of wanted catalog movies (TMDB/IMDb id, year and title) through each
  site's own search, so a missing film is found without crawling thousands of pages. See
  [Targeted search](#targeted-search).

## Access policy

- **Honest identity.** Every request sends `Mozilla/5.0 (compatible; Streamix/1.0; +https://streamix.mahina.fun)`.
  This is the same User-Agent as the YTS and JSON-feed clients. Streamix never spoofs a browser User-Agent.
- **No circumvention.** Streamix does not solve challenges, use FlareSolverr or replay cookies. A Cloudflare or
  DDoS-Guard challenge, a 403 or an interstitial page counts as a failure (`blocked`). Streamix then tries the next
  mirror.
- **Politeness.** Requests to one site are at least 1.5 s apart within a job. A node-wide bucket allows at most one
  request per site per 1.5 s window across jobs. HTTP 429 is never retried automatically: the caller backs off.

## Sites and mirrors

| Source         | Mirrors (tried in order)                                               | Listing / pagination                                     | Search                 |
|----------------|------------------------------------------------------------------------|----------------------------------------------------------|------------------------|
| ComandoTorrent | `comando1.com`, `comandotorrents.to`                                   | `article h2.entry-title a`, `/page/N/` (20/page)         | `/?s=`                 |
| GratisTorrent  | `gratistorrent.com`, `brutotorrent.com`, `apachetorrents.com`          | `div.col a.text-decoration-none`, `/pagina/N/` (30/page) | `/index.php?busca=`    |

Notes on these mirrors, verified 2026-10-12:

- `comando.la` serves a Cloudflare managed challenge to honest clients, so it is not a default mirror.
- `comandotorrents.co` serves the same posts with a different theme, so it is not configured.
- `brutotorrent.com` and `apachetorrents.com` publish GratisTorrent's catalog with their own themes. They have their
  own selector profiles in `GratisTorrent`.
- `semtorrent`, `redestorrents` and `limpotorrents` are left out:
  - Their layouts could not be verified.
  - `limpotorrents` does not put magnets in the page HTML.
- `hdrtorrents` is deliberately excluded. It puts "Dublado/Dual Áudio" in every title, which would mislead
  `ReleaseInfo`.

Movie identity:

- The identity of a scraped movie is its post URL, re-keyed onto the first configured mirror. The same post seen
  through `comandotorrents.to` therefore stays the same movie.
- Sister sites that use their own slugs keep their own URL as the identity.

### Configuration

The defaults live in the source modules. Every variable below is optional and only overrides a default:

| Variable                                     | Effect                                                                    |
|----------------------------------------------|---------------------------------------------------------------------------|
| `COMANDOTORRENT_ENABLED` / `GRATISTORRENT_…` | `false` switches the scraper off; the JSON feed (`*_SOURCE_URL`) is used. |
| `*_BASE_URLS`                                | Comma-separated, ordered mirror list. Replaces the defaults.              |
| `*_BASE_URL`                                 | Legacy single URL. Tried before the default mirrors.                      |
| `*_MAX_PAGES`                                | Newest listing pages crawled per nightly run (default 5).                 |
| `*_LIST_PATH`, `*_PAGE_PATH`, `*_SEARCH_PATH` | Paths. `{page}` and `{query}` are the placeholders.                       |
| `*_POST_SELECTOR`                            | Listing/search result link selector for the site's main theme.            |

For production, unset `COMANDOTORRENT_BASE_URL` if it still points to `comando.la`. Otherwise every job spends its
first request on the challenge before it falls back.

## Failure states

A source never reports an empty page as a successful sync. In `[Torrent SyncSource]` logs, Oban job errors and
`sync_provider/1` results, a source ends in one of these states:

| State            | Meaning                                                                                       |
|------------------|-----------------------------------------------------------------------------------------------|
| `ok`             | The page(s) were scraped. The log line includes the movie and torrent counts.                 |
| `disabled`       | Nothing is configured (scraper switched off, no feed). This is not a success.                 |
| `blocked`        | Every mirror answered with a challenge, a 403 or an interstitial. `attempts` lists each mirror. |
| `layout_changed` | The page was fetched, but the post selector matched nothing, or a whole page of posts lost its magnets. |
| `rate_limited`   | HTTP 429. Includes `retry_after_ms` when the site sent `Retry-After`.                         |
| `http_error` / `not_found` / `transport_error` | Other upstream failures.                                        |

Log lines look like this:

```
[Torrent SyncSource] provider=1 slug=comandotorrent failed state=blocked: {:blocked, %{...}}
```

`Streamix.Torrent.failure_state/1` returns the same names.

## Release metadata

`ReleaseInfo` parses the post title and each magnet. Each file's audio comes from:

1. its own label and `dn=` name;
2. otherwise, its section heading;
3. otherwise, the post title.

For example, a subtitled 4K file inside a "Dual Áudio" post is labelled `legendado`.

Some releases are flagged in `torrent_streams.release_flags`. They are kept, but
`Streamix.Torrent.best_stream_for_movie/1` and `streams_for_movie/1` rank them after every clean release:

| Flag             | Release type                                                   | Effect                                      |
|------------------|----------------------------------------------------------------|---------------------------------------------|
| `unofficial_dub` | "Dublado Não Oficial", "Dublagem Não Oficial", "Fan Dub"       | `audio_track` is `dublado_nao_oficial`, never `dublado` or `dual`. |
| `cam`            | CAM, CAMRip, HDCAM, TS/HD-TS, TS-cam, telesync                 | Ranked after clean releases.                |

Seasons, miniseries and multi-movie bundles (trilogies, "todos os filmes", listões) are skipped. The movie catalog
does not ingest them.

The IMDb id is read from each detail page: from the JSON-LD `sameAs` link, or otherwise from the IMDb link in the post.
Streamix stores it on the movie. When the rest of the catalog pairs that IMDb id with exactly one TMDB id, the torrent
movie gets that TMDB id at ingestion, so it does not depend on the fuzzy title matcher. The torrent provider's own rows
are ignored for this lookup, so an id it obtained by fuzzy matching is never fed back to it. The lookup runs for every
torrent source, YTS included, and uses the `movies_imdb_id_idx` partial index.

## Targeted search

Targeted search runs `Streamix.Torrent.TargetedSearch` for each wanted movie:

1. It searches each site, using the title as a query of up to six words.
2. It opens at most 3 results whose URL slug and snippet contain the title words, with a year within ±1.
3. It keeps the posts that match the wanted movie:
   - **IMDb first:** an equal IMDb id matches, and a different IMDb id never matches.
   - **Otherwise title + year:** the normalized title or original title must be equal, and the years at most one
     apart.
4. It ingests the matches through the normal sync pipeline, stamped with the wanted TMDB and IMDb ids.

The run stops on:

- 3 consecutive 429s, which pause the title for a later retry;
- a block, on every mirror;
- a layout change.

Ordinary errors are counted and skipped.

### Running it for the 490 wanted movies

The input is a headerless CSV: `tmdb_id,imdb_id,year,title`. `imdb_id` and `year` may be empty. Any extra commas
belong to the title.

1. Apply the migrations: they add `torrent_streams.release_flags` and build the `movies_imdb_id_idx` partial index
   concurrently. Make sure `TORRENT_ENABLED=true`.

   ```sh
   docker exec streamix bin/migrate
   ```

2. Copy the list into the container, then open a remote console:

   ```sh
   docker cp unique490.csv streamix:/tmp/unique490.csv
   docker exec -it streamix bin/streamix remote
   ```

3. In the console, parse the CSV and enqueue the search:

   ```elixir
   {:ok, wanted} = Streamix.Torrent.read_wanted_csv("/tmp/unique490.csv")
   length(wanted)
   #=> 490

   # One job per searchable source (comandotorrent, gratistorrent).
   {:ok, jobs} = Streamix.Torrent.enqueue_targeted_search(wanted)

   # Or a single site:
   {:ok, [job]} = Streamix.Torrent.enqueue_targeted_search(wanted, sources: ["gratistorrent"])
   ```

#### How the jobs run

- Each `TargetedSearchWorker` job goes through the list in order. It uses one search request plus at most 3 post
  requests per title, at 1.5 s per request. A full list takes roughly 15–50 minutes per site.
- The two jobs run in parallel on different sites, in the `torrent_sync` queue (concurrency 2). They share that queue
  with the nightly crawl, so avoid enqueueing around 04:00 UTC.
- After each title, the job saves `meta.next_index`, `searched`, `matched` and `torrents` to `oban_jobs.meta`.
- A rate-limited or blocked run is retried with a backoff of 15 minutes × attempt, up to 5 attempts. Each retry resumes
  at `next_index`.
- A layout change cancels the job instead of retrying it.
- Only one job per provider and source can be pending at a time.

#### Monitoring

Follow the `[Torrent TargetedSearch]` log lines. There is one per title (`matched … via imdb`, `no match`,
`no search result`) and a summary at the end.

#### Running it synchronously

For a few titles, without Oban:

```elixir
{:ok, provider} = Streamix.Providers.ensure_torrent_provider()
source = Streamix.Torrent.source_for("comandotorrent")
{:ok, wanted} = Streamix.Torrent.normalize_wanted([%{tmdb_id: 1003469, imdb_id: "tt18559372", year: 2022, title: "Combinação do Azevinho"}])
Streamix.Torrent.targeted_search(provider, source, wanted)
```

A synchronous run does not refresh the catalog read model. Afterwards, call
`Streamix.Torrent.refresh_catalog_stats(provider.id)` so the new movies appear on the torrent screen. The worker does
this on its own.

#### Limitations

- Titles that are mostly non-Latin, such as a Chinese PT-BR title, are not searched. They are reported as
  `unsearchable`.
- A wanted movie without a year can only match by IMDb id.
