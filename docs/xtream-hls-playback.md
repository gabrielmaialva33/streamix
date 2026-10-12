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
it never leaves this process and is never logged. The master is fetched afresh
on each master request; a session is reused for new starts for
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
