# Embedplay movie playback

The optional provider uses a private browser resolver and the Streamix HLS
gateway. It is disabled by default. Import and metadata enrichment are described
in [embedplay-catalog.md](embedplay-catalog.md); the private resolver has its own
[service README](../services/embedplay-resolver/README.md).

## Request flow

1. Catalog movie detail and `/api/v1/catalog/movies/:id/stream` mint the existing
   movie `StreamToken`. Both native and browser URLs point to
   `/api/stream/embedplay/master.m3u8?token=...` on Streamix. The URL suffix and
   response MIME identify HLS to the TV client; no embed or advertising page is
   mounted by the client.
2. Every master/resource request verifies the signature, its two-hour age,
   provider identity and active state, ownership/visibility, and the existing
   global-content subscription policy. Catalog API tokens retain the current
   API-key-authorized subscription bypass; browser user tokens do not gain it.
3. `HEAD` authorizes and advertises HLS without starting a browser. The first
   `GET` invokes the private authenticated `POST /resolve` using the movie's
   TMDB/IMDb identifiers and the `dubbed` audio preference. The gateway waits
   for a bounded response; clients do not need a new `202` polling contract.
4. The resolver returns a manifest URL, optional explicit `expires_at`, and a
   narrowly allowed header map. These values remain server-side. Streamix
   creates an opaque session tied to that movie and registers its manifest.
5. Streamix rewrites variant playlists, audio/subtitle renditions, segments,
   initialization maps, encryption keys and other quoted URI attributes into
   `/api/stream/embedplay/:session_id/:resource_id?token=...`. Each resource is
   looked up in that session's registry and authorized with the original movie
   token. There is no caller-supplied upstream URL parameter.

The web player also emits this HLS URL. Existing generic movie proxy URLs
redirect to the gateway while preserving the original token. Endpoint-backed
tests cover `HEAD`, because Phoenix's `Plug.Head` changes `conn.method` to GET;
the controller reads the already-preserved original method.

## Cache, expiry and limits

`EMBEDPLAY_SESSION_TTL_SECONDS` controls how long a resolved session is reused
for **new playback starts**, default 600 seconds. It does not terminate an
actively playing 90-minute movie. A resource graph survives while used, with
30 minutes of inactivity triggering cleanup. An explicit resolver expiry takes
precedence; an absent expiry is never inferred from opaque URL parameters.

Concurrent first starts of the same movie share one resolver task. The default
maximum is 128 sessions/pending resolutions, 64 waiters per resolution and 16
concurrent media requests. Each session can register at most 20,000 resource
identities and 4 MiB of upstream URL text. Cleanup runs every minute. Session
storage is process-local: a multi-node deployment needs sticky routing or a
shared registry implementation before this feature is enabled there.

Upstream `401`, `403` or `410` invalidates the entire old graph and returns
`409 playback_restart_required`. A fresh master request resolves again. Old
segment identifiers are never silently rebound to different bytes. Unknown or
already-cleaned resource IDs return `404 resource_not_found`. This first version
uses the player's existing fresh-stream retry path; automatic uninterrupted
mid-movie renewal is not claimed.

## Transport and media constraints

- Requests use Req with automatic redirects/retries disabled. Every media URL
  and every manually followed redirect is checked by the existing SSRF
  validator. Only HTTP(S), without URL userinfo, can be fetched. There are at
  most five redirects; each HTTP attempt has a 15-second deadline and a
  5-second connection timeout.
- Resolver transport uses a configured private address and bearer secret;
  redirects are disabled there too. The default total resolve timeout is
  45 seconds. Resolver capacity and timeout responses become sanitized `503`
  and `504` playback errors, without exposing service credentials or URLs.
- Media responses are collected with a 32 MiB cap per request; playlist parsing
  has a 2 MiB cap. This is a bounded segment gateway, not a progressive movie
  download proxy. Large individual segments can exceed that limit.
- `GET`, `HEAD`, CORS and a single byte range are supported. Manifest range
  probes are answered with the complete rewritten manifest. Media byte ranges
  and `Content-Range` are preserved. Multi-range requests are rejected.
- Media MIME types are allowlisted; unknown types, including upstream HTML or
  SVG, become `application/octet-stream`. Responses carry `nosniff` and a
  sandbox CSP so an upstream error/ad document cannot become active Streamix
  origin content.
- Resolver headers are restricted to `User-Agent`, `Referer` and `Origin`.
  Cookie/Authorization-based media hosts are not supported by this first slice.
- Relative references follow URI resolution semantics: a child path does not
  inherit the master's signed query, while an explicitly query-only reference
  keeps its base path. Existing query values are not decoded/re-encoded.
- HLS variable definitions and content steering fail explicitly rather than
  retaining external fetch instructions. Embedded advertising in the actual
  media timeline is not removed. DRM decryption and transcoding are not part
  of this adapter.

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

Fixtures exercise master → media → key/init/ranged segment, URI query
preservation, malformed attributes and unsupported playlists, signed-token
failures, active provider checks, SSRF redirects, oversized bodies, safe MIME,
resolver single-flight, cache freshness versus active lifetime, idle cleanup,
and explicit restart after upstream authorization expiry. These checks do not
contact a live media source or consume real stream URLs.

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
