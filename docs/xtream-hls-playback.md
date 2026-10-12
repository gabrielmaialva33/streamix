# Xtream HLS playback

Some Xtream providers deliver VOD as HLS: a movie or episode whose
`container_extension` is `m3u8` answers its Xtream URL with a master playlist,
not a byte-range file. The progressive token proxy (`/api/stream/proxy`,
`VodProxy`/`VodMultiplexer`) treats every movie as one file and only timed out
on these items (`[VodMux] block miss: :block_deadline_exceeded`). They now play
through an HLS gateway built on the same shared modules as the Embedplay
gateway ([embedplay-playback.md](embedplay-playback.md)).

## Upstream behaviour (measured from the production server)

- `GET https://<panel>/movie/<user>/<pass>/<stream_id>.m3u8` → one redirect →
  `200 application/vnd.apple.mpegurl` master playlist with `#EXT-X-MEDIA`
  audio renditions and variants. Episodes use
  `/series/<user>/<pass>/<episode_id>.m3u8` (the `/movie/` path 404s for them)
  and answer `200 application/x-mpegurl` the same way.
- Variant playlists live on another host and answer `text/plain`; segments on
  that host answer `application/javascript` but are MPEG-TS (first byte
  `0x47`). Content types are therefore never used to classify a body.
- A plain GET with the provider User-Agent works; no cookies or special
  headers. Dead items answer `404 text/html "No playable stream found."`.

## Routes and the URL contract

| Route | Serves | `HEAD` |
| --- | --- | --- |
| `/api/stream/hls/master.m3u8?token=…` | the rewritten master | `200`, HLS type, no upstream request |
| `/api/stream/hls/:session_id/:resource_id?token=…` | variants, renditions, keys, segments | as `GET`, without a body |

Every player picks its engine from the URL before fetching a byte (the web
player sends any URL containing `.m3u8` to hls.js; both TV backends treat
`.m3u8` as HLS), so the minted URL is the contract. For an `m3u8` Xtream item:

- catalog API `stream_url` and `/api/v1/catalog/{movies,episodes}/:id/stream`
  → `<endpoint>/api/stream/hls/master.m3u8?token=…`;
- catalog API `browser_stream_url` →
  `<stream proxy>/proxy?url=<encoded master URL>&edge=1` (see below);
- the watch page (and the next-episode preload) → the master URL;
- an older `/api/stream/proxy?token=…` URL for the item → `302` to the master.

`mp4`/`mkv` items, GIndex rows and every other provider type are unchanged
and keep the progressive token proxy. The decision lives in one place,
`Streamix.Playback.xtream_delivery/2` (and `xtream_route/4` for minting),
which minting, the proxy redirect and the gateway's own authorization all
consult.

For a provider with `direct_client_playback`, `container_extension` is not
trusted: each item is probed at play time
([xtream-direct-playback.md](xtream-direct-playback.md)), and a source that
answers HLS is served by this gateway rooted at that source's `?source=N`
URL — whatever the catalogue extension says.

Resource identifiers are opaque (144 random bits). Playlists end in `.m3u8`;
media keeps a known upstream extension (`.ts`, `.aac`, `.m4s`, `.mp4`, `.key`,
`.vtt`, …) so players that infer the container from the URL see it, and
anything else — including CDNs that disguise segments as `.js` — becomes
`.bin`.

### Behind the browser stream proxy (`source.mahina.fun`)

`browser_stream_url` goes through the nginx stream proxy like every other
browser URL. That proxy forwards one URL per request (`/proxy?url=…`), so a
playlist with root-relative references would resolve them against the proxy
host. The master URL minted for it therefore carries `edge=1`, and the
gateway then writes every reference as
`<stream proxy>/proxy?url=<encoded absolute gateway URL>&edge=1`: the player
stays behind the proxy for every playlist, key and segment. The proxy base
comes from `:stream_proxy_url`, never from the request. Gateway responses
carry `Cache-Control: private, no-store`, so the proxy's cache never stores
them. The web watch page uses the gateway origin directly (hls.js is
CORS-capable and the gateway answers with `Access-Control-Allow-Origin: *`).

## Authorization

Every request verifies the signed movie/episode token with exactly the checks
of the progressive flow — signature, ownership or visibility, the
global-content subscription policy, and the API-key bypass (the token's own
`bypass` claim, or a valid `X-API-Key` on the request) — plus the provider's
operator switch (`is_active: false` → `503 provider_disabled`) and automatic
health (`health_status: :degraded` → `503 provider_degraded`). Authorization
runs before the provider state is revealed.

- The master request (start of playback) also requires the item to be HLS
  (`409 stream_format_mismatch` otherwise) and applies the normal two-hour
  token age.
- Resource requests are authorized with the original token and are served
  only from a session opened for that same item (`404 resource_not_found`
  for a different item, an unknown id or a dropped session). A VOD player
  loads its playlists once and requests segments with the start token for as
  long as playback lasts, so resource requests accept the token for six hours
  instead of two; a new start still needs a fresh token.

## Sessions and leases

`Streamix.Iptv.Streaming.XtreamHls.Sessions` keeps one session per item whose
registry root is the item's Xtream URL. That URL embeds the account password;
it never leaves this process and is never logged. A VOD playlist is fetched
once per session (see "Keeping up with real time"); a session is reused for
new starts for
`XTREAM_HLS_SESSION_TTL_SECONDS` (600) while the source URL is unchanged,
stays alive while used, and is dropped after `XTREAM_HLS_IDLE_SECONDS` (1800)
without a request (`409 playback_restart_required` on the next resource) or
when an upstream answers `401`/`403`/`410` for one of its resources. At most
`XTREAM_HLS_MAX_SESSIONS` (2048) exist at once.

Every upstream fetch holds a per-provider lease for its duration. At most
`XTREAM_HLS_MAX_FETCHES_PER_PROVIDER` (16) run at once per provider; a request
beyond that waits in a FIFO for up to `XTREAM_HLS_LEASE_WAIT_MS` (5000) and
then fails with `503 provider_capacity_exhausted`. Segment fetches are short,
so this bounds concurrent upstream requests, not viewers. HLS fetches do not
consume the progressive `ProviderRuntime` VOD slots (`VOD_CONNECTION_CEILING`),
because the segments live on the provider's CDN rather than the panel. State
is node-local: a multi-node deployment needs sticky routing first.

## Keeping up with real time

Measured on 2026-10-12 against production (movie 36953421, MegaEmbed): on a
Tizen AVPlay emulator the first gateway release played at 0.75× real time
with 4–5 s stalls, and a seek to 50% failed (`PLAYER_ERROR_SEEK_FAILED`).
Host-side, the 720p media playlist (653 KB, 2,646 two-second segments, VOD
with `#EXT-X-ENDLIST`) took 4.9–7.8 s on every request — the gateway refetched
and rewrote it each time, and AVPlay refetches it on seek — and a cold segment
took 2.2–5.6 s to its first byte (8 consecutive segments, 16 s of video, took
36 s), while a warm one took 0.3–0.6 s. The latency is the CDN's, per segment.

What the gateway does now:

- **Immutable playlists are cached in the session.** A master, or a media
  playlist with `#EXT-X-ENDLIST`, is kept after its first fetch as a template
  of resource ids and rendered for each request with that viewer's own
  token, so a seek (or another viewer) never refetches it. The rendered text
  is never cached: its URLs carry the requesting viewer's token. A media
  playlist without `#EXT-X-ENDLIST` (live/event) is always refetched. Bound:
  `XTREAM_HLS_PLAYLIST_CACHE_BYTES` (8 MiB) per session; it goes when the
  session idles.
- **Bounded lookahead.** A request for segment N prefetches the next
  `XTREAM_HLS_PREFETCH_SEGMENTS` (3) of the same playlist into
  `Streamix.Hls.SegmentCache`, a shared single-flight cache (whole `200`
  media bodies only, `HLS_SEGMENT_CACHE_TTL_MS` 45 s, `HLS_SEGMENT_CACHE_MAX_BYTES`
  128 MiB, oldest first out, entries over 16 MiB never kept). At most
  `XTREAM_HLS_PREFETCH_CONCURRENCY` (3) prefetches are in flight per session;
  a finished prefetch refills the window ahead of the latest segment the
  player asked for, per rendition, and a failed one is never retried. The
  player's own request joins a prefetch in flight or finds it cached. Every
  fetch still takes the per-provider lease. This is a player's forward
  buffer: each segment is fetched once, over one ordinary connection; no
  segment is split into parallel byte ranges or given extra connections.
- **Connections and deadlines.** Upstream requests use the
  `Streamix.HlsFinch` HTTP/1 keep-alive pool (32 connections per host, idle
  connections kept 30 s). A segment or key fetch may take
  `XTREAM_HLS_MEDIA_TIMEOUT_MS` (90 s) in total (it was 15 s) with at most 15 s
  between two reads, because the CDN serves each connection at roughly
  0.5–1 Mbit/s.

Benchmark (scratchpad script, not in the repo): master → variant → 8
consecutive segments from #1300, then a seek (variant again → 8 segments from
#1800), against a fake upstream injecting the measured latencies (variant
4.9–7.8 s; cold segment 2.2–5.6 s, warm 0.3–0.6 s), requests issued back to
back as a buffering player does:

| Path | start (master + variant + 8 segments) | 8 segments alone | seek (variant + 8 segments) |
| --- | --- | --- | --- |
| before (refetch every playlist, no cache, no lookahead) | 36.9 s → 0.43× | 0.53× | 37.3 s → 0.43× (variant 6.1 s) |
| after | 17.6 s → 0.91× | 1.62× | 14.4 s → 1.11× (variant 6 ms) |

The cold start still pays the first variant fetch (5–8 s), once per session.
Keep-alive: against a public HTTPS CDN, eight sequential small requests took
a median 65 ms over fresh TLS connections and 38–50 ms reused. The previous
code already reused connections through Req's implicit per-options pool, so
the explicit pool adds sizing and idle limits rather than a measurable TTFB
gain; the per-segment latency is the CDN's cold fetch, which the lookahead
hides. Not yet re-measured on AVPlay against production.

## Transport, errors and safety

Fetching, redirects and rewriting are the shared gateway's (see
[embedplay-playback.md](embedplay-playback.md)): at most five manually followed
redirects, each SSRF-checked before it is requested (including the first hop,
so a provider URL on a private address is refused); a 32 MiB body cap and a
2 MiB playlist cap; URI-semantics resolution of relative references;
variable definitions and content steering refused. A visibly MPEG-TS body is
served as `video/mp2t`; other media keeps an allowlisted type or becomes
`application/octet-stream`; every response is `nosniff`, sandboxed by CSP and
CORS-open.

| Condition | Response |
| --- | --- |
| master answers `404` (dead item) | `404 upstream_not_found`, at once — no timeout, no fallback clip |
| master answers `401`/`403`/`410` | `502 upstream_unavailable` |
| resource answers `401`/`403`/`410` | `409 playback_restart_required`; the session is dropped |
| a hop points at a private address | `403 unsafe_url` |
| playlist uses `#EXT-X-DEFINE`/steering | `502 stream_resolution_failed` |
| multi-range request | `416 invalid_range` |

Errors use the stream proxy's JSON vocabulary
(`{"error": {"code", "message", "retry_after"?}}`).

## Deterministic checks

```sh
mix test test/streamix/hls \
  test/streamix/iptv/streaming/xtream_hls \
  test/streamix_web/controllers/xtream_hls_controller_test.exs
```

The fixtures use `Req.Test` only: a master behind a panel redirect with audio
renditions and variants on another host, a `text/plain` variant,
`application/javascript` TS segments, relative, root-relative and absolute
references, ranged segments, SSRF on a redirect hop and on a playlist
reference, credentials absent from every body, header and log line, token
failures, private-provider ownership, inactive and degraded providers, a dead
item's `404`, the per-provider lease cap, episodes on `/series/`, the
browser-proxy (`edge=1`) rewrite, minted URLs on every surface, and `mp4`
items left on the token proxy.

Not verified here: physical Samsung AVPlay playback of these playlists
(alternate audio renditions, `.bin` segment names), and source-wide coverage
of the provider's catalogue.
