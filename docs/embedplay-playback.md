# Embedplay movie playback

The optional provider uses a private browser resolver and a Streamix playback
gateway that serves either a progressive MP4 file or an HLS stream. It is
disabled by default. Import and metadata enrichment are described in
[embedplay-catalog.md](embedplay-catalog.md); the private resolver has its own
[service README](../services/embedplay-resolver/README.md).

The only usable upstream source now delivers **one progressive MP4 per movie**
(about 1–2 GB), not HLS. Catalog URLs therefore point at the MP4 route. The HLS
route and gateway remain for sources that still resolve to a playlist.

## Resolver contract

`POST /resolve` (private address, bearer secret, redirects disabled) answers:

```json
{ "kind": "mp4" | "hls", "media_url": "https://...", "manifest_url": "<hls only, equal to media_url>",
  "expires_at": null | "<ISO8601>", "headers": { "referer": "...", "user-agent": "..." } }
```

- `kind` selects the session type. A resolver still on the previous contract
  sends no `kind`, only `manifest_url`; that is read as HLS, so Streamix and the
  resolver can be redeployed in either order. An unknown `kind`, a missing URL,
  or a URL failing the SSRF validator is a resolution failure; it is never guessed.
- Headers are restricted to `User-Agent`, `Referer` and `Origin` (at most eight,
  2 KiB each, no CR/LF). Cookie/Authorization-based media hosts are unsupported.
  The resolver itself only ever returns `user-agent` and `referer`.
- Errors: `503` → `provider_capacity_exhausted`, `504` → `upstream_timeout`.
  A `502` body is read: `stream_unavailable` → `no_source_available` (`503`,
  retryable, per attempt); `unsupported_page` → `resolver_outdated` (`503`). The
  latter means the resolver's adapter no longer matches the upstream page, so
  every title fails alike until the adapter is fixed; it is systemic, not
  per-title, and health monitoring keys on the `:resolver_outdated` atom.
  `challenge_required` → `challenge_required` (`503`): the upstream answered the
  resolver's browser with a human challenge, which is never solved or evaded;
  health counts it by the same rate rule as `no_source_available`.
  Anything else becomes `502 stream_resolution_failed`.

## Routes and the client contract

| Route | Serves | `HEAD` |
| --- | --- | --- |
| `/api/stream/embedplay/video.mp4?token=…` | MP4 sessions only | `200`, `video/mp4`, `Accept-Ranges: bytes`; no resolution |
| `/api/stream/embedplay/master.m3u8?token=…` | HLS sessions only | `200`, HLS MIME; no resolution |
| `/api/stream/embedplay/:session_id/:resource_id?token=…` | HLS playlists, segments, keys | as `GET`, without a body |

**The URL suffix is the contract.** Every client chooses its playback engine
from the URL before fetching a byte, so the response cannot correct a wrong
choice:

- The web player routes any URL containing `.m3u8` to hls.js
  (`assets/js/media/stream_loader.js`); its `data-stream-type` comes from the
  movie's `container_extension`. EmbedPlay imports now store `mp4`, and the
  `20261012181003` migration converts existing EmbedPlay rows (reversibly).
  With `.mp4` it selects native `<video>`.
- On Samsung TVs the TV app's AVPlay backend enables adaptive (HLS) mode for
  `.m3u8` URLs; MP4 bytes then stall until its 20-second prepare timeout.
- The TV app's HTML5 backend forces hls.js for `.m3u8` whatever the
  `Content-Type`; otherwise it probes with `HEAD` and plays `video/mp4` natively.

So MP4 bytes are never served from, or redirected to from, a `.m3u8` URL. The
catalog API (`stream_url`, `browser_stream_url`, `/api/v1/catalog/movies/:id/stream`),
the watch page, and the generic `/api/stream/proxy?token=…` fallback redirect all
mint the `video.mp4` URL. TV installs receive it from the API, so no TV release
is needed. Each route serves exactly one format: if `video.mp4` resolves to an
HLS session, or `master.m3u8` to an MP4 one, the request fails with
`409 stream_format_mismatch` instead of cross-serving. A consequence: while the
catalog mints only `video.mp4`, a title whose resolver answer is HLS has no
playable catalog URL.

`HEAD` on `video.mp4` authorizes the token and answers without resolving,
because resolution runs a browser for about ten seconds. It cannot know the
length yet, so it sends no `Content-Length`.

## Request flow

1. Catalog movie detail, `/api/v1/catalog/movies/:id/stream` and the watch page
   mint the existing movie `StreamToken`. No embed or advertising page is ever
   mounted by a client.
2. Every request verifies the signature, its two-hour age, provider identity
   and active state, ownership/visibility, and the global-content subscription
   policy. Catalog API tokens retain the API-key subscription bypass; browser
   user tokens do not gain it.
3. A `GET` opens the movie: concurrent first starts share one resolver call,
   whose answer stays server-side. Streamix creates an opaque session tied to
   the movie. An MP4 session's root is one media resource (an opaque id ending
   `.mp4`); an HLS session's root is a playlist.
4. MP4: the gateway streams the file (below). HLS: playlists are rewritten so
   variants, renditions, segments, initialization maps, keys and other quoted
   URI attributes become `/api/stream/embedplay/:session_id/:resource_id?token=…`,
   each looked up in that session's registry. There is never a caller-supplied
   upstream URL parameter.

Endpoint-backed tests cover `HEAD`, because Phoenix's `Plug.Head` changes
`conn.method` to GET; the controller reads the already-preserved original method.

## Progressive MP4 delivery

**The source.** The resolver returns a URL such as
`https://<random>.sssrr.org/sora/<id>/<token>`. It requires
`Referer: https://abysscdn.com/` and a browser `User-Agent` (without the
Referer it answers a 403 Cloudflare page; an `Origin` header makes it 404; no
cookie is needed), then redirects to an ephemeral `https://<words>.trycloudflare.com/…`
host that answers ranges with `206 video/mp4`. The resolver-provided headers and
the client's `Range` are sent unchanged on **every** redirect hop; Streamix never
adds an `Origin`. Each hop (at most five) passes the SSRF validator first.

**Streaming passthrough.** The client's single `Range` (or none) goes upstream
as-is, and the upstream status, `Content-Range`, `Content-Length` and
`Accept-Ranges` come back as-is, so seeking keeps exact HTTP range semantics on
every player:

- no `Range` → `200` with the whole file, streamed; never `206`. An upstream
  that answers `206` to a request without a `Range` is refused (`502`), because
  `206` is only valid in reply to a range request;
- `bytes=N-`, `bytes=N-M`, `bytes=-N` → forwarded unchanged; the upstream `206`
  and its `Content-Range` (with the total length) are passed through;
- multi-range → `416 invalid_range`; an upstream `416` → `416`.

The body is never collected. Each chunk is written to the client before the
next is read from upstream, and that read runs in the request process, so a
slow client slows the upstream read through TCP backpressure instead of growing
a buffer: a request holds one socket read of the movie at a time (≤128 KiB was
observed). A client that disconnects (a seek, a closed tab) makes the write
fail, which halts the transfer, closes that upstream connection and releases the
lease. The progressive root is never reachable through the buffered resource
route, which keeps its 32 MiB cap for playlists and segments only.

Bounded-window clamping (answering a wide range with a short `206` from a
buffered window) was the alternative. It was rejected because it rewrites range
semantics — a request without `Range` would get a `206`, whose handling by
Samsung AVPlay is unverified — and delays the first byte by a whole window.

**Response headers.** The media type follows the allowlist (`video/mp4`, else
`application/octet-stream`), with `nosniff`, the sandbox CSP and CORS. Streamed
responses carry `Cache-Control: private, no-store, no-transform`, which also
stops response compression from changing a byte range, and on HTTP/1.x
`Connection: close`: if the upstream fails mid-body, the response ends short of
its declared length and the closed connection makes that visible at once, so
the player re-requests the range instead of waiting on a kept-alive socket.
Streamix does not resume such a transfer itself.

**Transport.** Transfers use the dedicated HTTP/1 `Streamix.StreamFinch` pool
(25 × 4 connections per upstream host; Finch documents no backpressure for
HTTP/2 response streaming), a 5-second pool checkout, a 15-second idle timeout
between upstream reads, and no total deadline, since one response may last as
long as the movie. Its connection timeout is the pool default, not the 5 s used
for playlist and resolver requests.

## Sessions, cache, expiry and capacity

`EMBEDPLAY_SESSION_TTL_SECONDS` (default 600) controls how long an **HLS**
resolution is reused for new playback starts; it never ends an active stream,
which keeps its resource graph while used. An **MP4** session is instead reused
for as long as it is alive: a progressive movie has one stable URL and every
range request (each seek or reconnect) opens the movie again, so applying the
TTL would re-resolve mid-movie (a ten-second browser run per request) and could
move later ranges of one playback onto a different file. A long transfer
reports activity at most once a minute, so a session stays alive while bytes
flow.

Every session ends after 30 minutes without activity (cleanup runs each
minute), at an explicit resolver `expires_at`, or when the upstream answers
`401`, `403` or `410`. That last case invalidates the whole session and returns
`409 playback_restart_required`; the next request resolves again. For MP4, a
read from byte 0 renews once within the same request (it parses the file
afresh, sparing a new viewer a failed first play on a stale cached source); a
later range is not retried, because a new resolution might be a different file
whose bytes would not continue the ones the player holds. Unknown or cleaned
resource IDs return `404 resource_not_found`. No expiry is inferred from opaque
URL parameters.

Defaults: 128 sessions/pending resolutions, 64 waiters per resolution, and 64
concurrent fetch leases (`EMBEDPLAY_MAX_CONCURRENT_FETCHES`, up to 512). An HLS
playlist, key or segment holds a lease only for its short fetch. **An MP4
transfer holds its lease for as long as the player keeps that response open —
often the whole movie — plus a brief overlap while a seek replaces it.** For MP4
sources the lease cap is therefore roughly the number of concurrent viewers, and
a seek while it is exhausted gets `503 provider_capacity_exhausted` for that
range. The default is unchanged; raise it for more concurrent viewers, keeping
in mind the 100 pooled connections per upstream host. Each HLS session can
register at most 20,000 resource identities and 4 MiB of upstream URL text.
Session storage is process-local: a multi-node deployment needs sticky routing
or a shared registry before this feature is enabled there.

How long an upstream `media_url` stays valid is unknown. A transfer already in
progress is unaffected by later expiry; the first new request after it (a seek,
a reconnect) gets `409 playback_restart_required`, or, from byte 0, a fresh
resolution. Automatic uninterrupted mid-movie renewal is not claimed. Signed
tokens also expire two hours after minting.

## HLS transport and media constraints

- Requests use Req with automatic redirects/retries disabled; every media URL
  and manually followed redirect is SSRF-checked; only HTTP(S) without userinfo;
  at most five redirects; 15-second deadline and 5-second connect timeout per
  attempt. Resolver timeouts default to 45 seconds.
- Media responses are collected with a 32 MiB cap per request; playlist parsing
  has a 2 MiB cap. Large individual segments can exceed that limit.
- `GET`, `HEAD`, CORS and a single byte range are supported. Manifest range
  probes are answered with the complete rewritten manifest. Media byte ranges
  and `Content-Range` are preserved. Multi-range requests are rejected.
- Unknown media types, including upstream HTML or SVG, become
  `application/octet-stream`, with `nosniff` and a sandbox CSP.
- Relative references follow URI resolution semantics: a child path does not
  inherit the master's signed query, while an explicitly query-only reference
  keeps its base path. Existing query values are not decoded/re-encoded.
- HLS variable definitions and content steering fail explicitly. Embedded
  advertising in the media timeline is not removed; DRM decryption and
  transcoding are not part of this adapter.

Movies are the only supported catalog type. A TMDB season/episode entry alone
does not establish source availability. Physical Samsung playback, source-wide
coverage, upstream longevity and production-origin reachability require a
separate authorized validation before enabling production traffic.

## Deterministic checks

```sh
mix test test/streamix/embedplay/hls_test.exs \
  test/streamix/embedplay/http_test.exs \
  test/streamix_web/controllers/embedplay_stream_controller_test.exs \
  test/streamix_web/stream_token_test.exs
```

Fixtures exercise the new (MP4 and HLS) and legacy resolver contracts,
`unsupported_page`, MP4 session roots, `HEAD` on `video.mp4` without
resolution, a no-`Range` `GET` streamed as `200`, `Range` passthrough
(`N-M`, `N-`, `-N`, past the end), refusal of an upstream `206` to a
no-`Range` request, multi-range rejection, header forwarding across the
redirect to the tunnel host without `Origin`, a halting sink, `403` →
restart and renewal from byte 0, MP4 session reuse past the TTL and idle
cleanup, format mismatch on both routes, the three minted URLs, the
`container_extension` hint, and the unchanged HLS path (master → media →
key/init/ranged segment, URI query preservation, malformed attributes,
signed-token failures, active provider checks, SSRF redirects, oversized
bodies, safe MIME, resolver single-flight, cache freshness versus active
lifetime). These checks do not contact a live media source or consume real
stream URLs.

## Progressive MP4 change recorded on 2026-10-12

The source facts above were measured from the production VPS with plain curl
on 2026-10-12. The Streamix side was verified with fixtures and, separately,
through a real Bandit socket in front of the endpoint with the upstream
stubbed: `Content-Length` was passed through without chunked encoding or
compression (even with `Accept-Encoding: gzip`), `206`/`Content-Range` came back
unchanged, `HEAD` carried `video/mp4` and `Accept-Ranges`, and closing the
client mid-body released the fetch lease. Not verified: a real upstream
transfer, a browser or physical Samsung TV playing the new URL, and upstream URL
lifetime. Nothing was deployed.

## Resolver change recorded on 2026-10-12

From mid-September 2026 every resolution failed with `stream_unavailable`. The
resolver drove only BYSE (its HLS path), which most titles no longer list (24 of 160
sampled selector pages still did, behind a player host that had rotated away from
the allowlisted `f7hyg4q.org`), and its anchored option pattern no longer matched
the now whitespace-padded labels, so even those were never selected. The supported server is now
ABYS (`embedplayabyss.top` → `abysscdn.com`), which serves progressive MP4 rather
than HLS. Its media URL (`*.sssrr.org`) redirects to an ephemeral
`*.trycloudflare.com` tunnel and answers `206 video/mp4` only with
`Referer: https://abysscdn.com/`; it answers 403 without it and 404 when an
`Origin` is added. No cookie is involved.

Success is `{"kind":"mp4","media_url":…,"expires_at":null,"headers":{"referer":…,"user-agent":…}}`.
An `hls` answer additionally carries `manifest_url` equal to `media_url`, which keeps
releases that read only `manifest_url` working; an `mp4` answer omits it, so such a
release fails cleanly instead of treating an MP4 as a playlist. `media_url` is the
URL the content player requested, before redirects. The resolver verifies it
outside the browser with exactly the returned headers before answering.

A new error code, `unsupported_page` (HTTP 502), reports that the page loaded but
no longer matches what the adapter can drive: no language control, no option shown,
an unknown server name with no supported one beside it, or a frame chain leading to
a host outside the allowlist. It means the adapter needs review, unlike
`stream_unavailable`, which stays the answer for one title without a verified
source (an unknown title, a language not offered, only unsupported servers, or
sources that exist only behind the player's service worker). Measurements, the
content-versus-advertising evidence and the allowlist are in the
[resolver README](../services/embedplay-resolver/README.md).

Current outcome: on 2026-10-12 abysscdn.com answered Chromium's headless
User-Agent with a Cloudflare managed challenge. The resolver keeps that User-Agent
and does not work around bot detection, so every ABYS title then ended as
`challenge_required` (HTTP 502) about 3 seconds after the request, from the
workstation. From the production VPS, a plain request to abysscdn.com with the
headless User-Agent drew the same `403` with `cf-mitigated: challenge`. Streamix
counts these towards provider health, so the catalog is hidden while it lasts and
the canary restores it if the upstream stops challenging.

## Validation recorded on 2026-09-09

- Full `mix precommit` passed: 1,448 checks (5 doctests and 1,443 tests), with
  26 excluded. Strict Credo and the coverage check passed. The private resolver's
  12 Node fixture tests also passed.
- A separate end-to-end run used temporary Phoenix, PostgreSQL 18 with
  TimescaleDB 2.30, and Redis. After importing TMDB movie `852854`, the public
  catalog filter and detail endpoints returned `200` and a signed gateway URL.
  The [private resolver](../services/embedplay-resolver/README.md) resolved its
  BYSE dubbed source in approximately 11.2 seconds.
- Chrome with hls.js played 1920×1080 video beyond five seconds, then sought to
  120 seconds and advanced beyond 122 seconds without a media error or fatal
  hls.js error. All seven observed media requests used the local Streamix
  gateway and returned `200`; the playback browser loaded no embed page or
  upstream media URL.

This validates one real movie through the
[catalog import](embedplay-catalog.md), resolver and gateway. It does not verify
physical TV hardware, production PostgreSQL 17, production-origin reachability,
or actual upstream token lifetime. Upstream expiry remains unknown; restart
behavior was verified with fixtures. The feature remains disabled by default,
and this validation did not deploy it.


The subsequent resolver performance pass retains one Chromium with bounded,
isolated contexts and adds sanitized stage timing records. Two live resolver-only
samples took 14.014 s and 12.466 s; context plus page creation took 43–45 ms and most
waiting occurred after BYSE selection. This does not establish a playback speedup.
The 20 Node checks passed, as did `mix precommit` on a fresh temporary test database
(1,448 checks, 26 excluded). No deployment was performed.
See [resolver lifecycle and measurements](../services/embedplay-resolver/README.md#browser-lifecycle-and-performance).
