# Xtream live channels over the HLS gateway

Streamix's live path (`LiveProxy` / `StreamMultiplexer`) expects a continuous
MPEG-TS byte stream from `/live/<user>/<pass>/<id>.ts`. Some providers answer
that URL with an HLS playlist instead, which the TS path cannot play. For a
provider with the operator-only `providers.probe_live_delivery` switch, each
channel is probed at play time and served through the HLS gateway
([xtream-hls-playback.md](xtream-hls-playback.md)) when it answers HLS.
Providers without the switch — every existing TS provider — keep the TS live
path exactly as before; nothing about them is probed or changed.

## Measured (MegaEmbed, provider 6, 137 channels, 2026-10-12)

- `GET /live/<u>/<p>/<id>.ts` and `.m3u8` both → one redirect → `200
  application/vnd.apple.mpegurl`, a **media** playlist (not a master) on
  `aws.s13-s1001604.lat`: no `#EXT-X-ENDLIST`, `#EXT-X-MEDIA-SEQUENCE`
  advancing (4209 → 4211 within seconds), `TARGETDURATION` 7–13, about five
  segments; segments `200 video/mp2t`, first byte `0x47`. The CDN accepts the
  server.
- Some "channels" are not streams: channel 123 redirects to an HTML page on a
  third-party embed site. Channel 81's playlist exists but its segment 404s
  (offline).
- **Throughput:** the CDN serves each connection at roughly 0.5–1 Mbit/s, both
  to the server and to a residential address, measured at 19–20h BRT (one
  connection: 1.76 MB in 27.8 s; three parallel connections summed to
  ~1.4 Mbit/s; parallel byte ranges of one segment also sum). Live bitrates are
  about 2.3–3.3 Mbit/s, so **at peak, live from this CDN will stall whatever the
  path** — the gateway, a direct player, or the TS proxy alike. Streamix does
  not work around the per-connection limit: no parallel byte ranges, no extra
  connections per segment. It behaves like a normal player: segments are
  fetched when asked for, prefetching at most the next one.

## Enabling it

```elixir
provider = Streamix.Providers.get_provider(6)
Streamix.Providers.update_provider(provider, %{probe_live_delivery: true})
```

The switch is cast only by the admin changeset (migration
`20261012223018_add_probe_live_delivery_to_providers`, `boolean not null
default false`). Turning it off returns the provider to the TS path at once
(cached probe decisions are keyed by provider and only used while it is on).

## The probe

`Streamix.Iptv.Streaming.DeliveryProbe` (the VOD per-item probe, extended to
channels) walks the channel's live URL with `RedirectResolver.final_hop/2`:
`GET`, manual redirects, SSRF validation on every hop, at most five redirects,
halted at the first body chunk (16 bytes kept). The final hop decides:

| Final hop | Decision |
| --- | --- |
| `200`/`206` with an HLS type or an `#EXTM3U` prefix | HLS gateway, rooted at the live URL |
| `200`/`206` whose first byte is `0x47` (or empty with `video/mp2t`) | the existing TS live proxy |
| any other `200` (an embed page) | `502 not_a_stream` — never served |
| `404`/`410` | `404 upstream_not_found` |
| anything else, or a transport failure | `502 upstream_unavailable` / `504 upstream_timeout` |

Decisions are cached per provider credentials and channel, with single-flight:
HLS `XTREAM_PROBE_HLS_TTL_SECONDS` (1800), TS `XTREAM_PROBE_TS_TTL_SECONDS`
(1800), failures `XTREAM_PROBE_FAILURE_TTL_SECONDS` (120). A failure is
reported, never a hang: the probe has an overall 20 s deadline and the live
playlist fetch an 8 s one.

## Routes and URL contract

The gateway routes are the VOD ones, now also taking channel tokens:

| Route | Live use |
| --- | --- |
| `/api/stream/hls/master.m3u8?token=…` | start: a one-variant master pointing at the live playlist resource |
| `/api/stream/hls/:session_id/:resource_id?token=…` | every playlist refresh, and the segments |

The channel's root is a media playlist, so the master route answers
`#EXT-X-STREAM-INF:BANDWIDTH=3000000` plus the root resource URL. Players then
refresh the live playlist through the resource route, pinned to the session
and its token policy, rather than starting playback over on every refresh.

Minting asks `Streamix.Playback.xtream_route(provider, :channel, channel)`: a
channel probed as HLS gets the `.m3u8` master URL on every surface — catalog
`stream_url` and `/api/v1/catalog/channels/:id/stream`, `browser_stream_url`
(through the stream proxy with `edge=1`, so every playlist reference stays
behind it), and the watch page. TS channels, failed probes and unflagged
providers keep `/api/stream/proxy?token=…`; for a flagged provider that proxy
redirects HLS channels to the master and refuses unavailable ones with their
error code (it never proxies an embed page). EPG pages link to the same watch
page; there is no separate EPG playback URL.

**Web player.** The live stream-type hint used to be hard-coded to `ts`, which
sent any live URL to mpegts.js. The hint now follows the minted URL
(`StreamixWeb.PlayerComponents.Metadata.stream_type/4`: an HLS gateway URL is
`m3u8`), and the player itself gives any URL containing `.m3u8` an HLS engine
whatever the hint (`resolveStreamType` in `assets/js/media/stream_loader.js`).
The same fix applies to VOD items a probe found to be HLS although catalogued
as `mp4`.

## Gateway live mode

- **No playlist caching.** Every refresh is fetched upstream
  (`XTREAM_HLS_LIVE_PLAYLIST_TIMEOUT_MS`, 8 s) and rewritten; a live playlist
  is never kept in the session (VOD playlists with `#EXT-X-ENDLIST` are).
- **Registry sliding window.** A live session's registry keeps, besides the
  root, only references a refresh named within `XTREAM_HLS_LIVE_WINDOW_SECONDS`
  (180); older segment ids stop resolving (`404 resource_not_found`, and the
  player reloads the playlist). A channel left running for days stays at its
  window instead of reaching the 20,000-resource / 4 MiB caps. Segments still
  listed keep their ids across refreshes.
- **Session lifetime.** One session per channel, shared by every viewer for as
  long as it is used, dropped after `XTREAM_HLS_LIVE_IDLE_SECONDS` (300)
  without a request.
- **Shared segment cache.** Live segments go through `Streamix.Hls.SegmentCache`
  keyed by upstream segment URL: concurrent viewers wait on one upstream
  fetch, later viewers read the stored response. Bounds: `HLS_SEGMENT_CACHE_TTL_MS`
  45 s (a few target durations), `HLS_SEGMENT_CACHE_MAX_BYTES` 128 MiB total
  with the oldest dropped first, entries over 16 MiB never kept. N viewers of a
  channel cost one upstream fetch per segment.
- **Lookahead.** At most the next segment (`XTREAM_HLS_LIVE_PREFETCH_SEGMENTS`,
  1; 0 disables it), under the per-provider lease.
- A segment fetch may take `XTREAM_HLS_MEDIA_TIMEOUT_MS` (90 s) in total, at
  most 15 s between reads.

## Token lifetime

A live playback can run for hours, so the rule for resources (playlist
refreshes and segments of an open session) is: the signed token is accepted
for **six hours** after it was minted while the session is alive; the start of
a playback (the master) keeps the normal two-hour window. Every other check —
ownership, subscription, provider active and healthy — runs on every request.
Past six hours the next refresh fails with `401 token_expired`, and the
player re-requests its stream URL: the web player does this on its own (its
HLS recovery requests `request_token_refresh` on 401/403 and reloads the new
URL at the live edge); a TV client re-requests
`/api/v1/catalog/channels/:id/stream`. No token is ever unbounded.

## Not covered

- Live channels marked dead/alive (`Channels.mark_dead/1`) are only updated by
  the TS path; a gateway `404` does not mark a channel dead.
- Throughput, as above: a CDN that serves each connection below the stream's
  bitrate cannot play in real time, and Streamix does not try to make it.
- Physical AVPlay playback of these live playlists is unverified.

## Deterministic checks

```sh
mix test test/streamix/iptv/streaming/delivery_probe_test.exs \
  test/streamix/hls test/streamix/iptv/streaming/xtream_hls \
  test/streamix_web/controllers/xtream_live_hls_test.exs \
  test/streamix_web/components/player/metadata_test.exs
cd assets && node --test --test-concurrency=4 js/test/stream_loader.test.js
```

`Req.Test` fixtures cover HLS, TS, embed-page, dead and failing channel
probes; minted `.m3u8` URLs on every surface with one probe; the one-variant
master; refreshes fetched upstream every time and rewritten as the media
sequence advances, with stable ids for segments still listed; eviction of
references outside the window down to root plus the current window; four
concurrent viewers sharing one segment fetch and a later viewer reading the
cache; segment cache TTL, bounds and never-cached results; the embed-page
channel refused on the gateway and the proxy; an offline segment's `404`; TS
providers (unflagged, and flagged channels answering TS) untouched; the token
policy (a 3-hour-old token refreshes a live playlist, starts nothing, and a
7-hour-old one is refused); credentials absent from responses and logs; and
the player's stream-type resolution.
