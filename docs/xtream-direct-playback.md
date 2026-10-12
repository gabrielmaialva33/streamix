# Xtream direct-client playback and per-item delivery probing

Some Xtream providers cannot be played from the Streamix server at all for
part of their catalogue, and their catalogue metadata does not say which part.
`providers.direct_client_playback` is the operator switch for such providers.
With it, every VOD item's delivery is decided per item at play time:

- **HLS** sources play through the HLS gateway
  ([xtream-hls-playback.md](xtream-hls-playback.md)), as for any `m3u8` item;
- **progressive** sources are handed to the client: after full token
  authorization, Streamix redirects the player to the final CDN URL it
  resolved server-side.

This is the one owner-approved exception to the AGENTS.md rule "do not leak
final upstream URLs to browsers", and it is limited to exactly that: flagged
providers, progressive VOD, and a final URL that never contains the account
password.

## Why (measured from the production server on 2026-10-12)

For the MegaEmbed provider (`provider_type: xtream`, 17,806 movies):

- `container_extension` is not a delivery format. Movie 100664 is listed as
  `mp4`, but `/movie/<u>/<p>/100664.mp4?source=1` answers
  `200 application/vnd.apple.mpegurl` from a CDN that accepts the server,
  while `?source=2` redirects to a progressive CDN that refuses it. The
  extension requested in the URL does not change what comes back; the
  provider documents `.txt` as an HLS extension too.
- Items carry a `sources` array (`get_vod_streams`, `get_vod_info`, series
  episodes): `[{source_id, name: "Fonte 1 (Principal)" | "Fonte 2 (Backup)" …,
  format, url: ".../<id>.<ext>?source=N"}]`. 6,279 movies have two or more
  sources (up to 13); `?source=N` on the standard URL selects one.
- A progressive source walks `GET https://<panel>/movie/<u>/<p>/<id>.mp4` →
  `302` → `https://<redirector>/…` → `302` →
  `http://<host>.<rand>.com:80/movies/<n>/<n>.mp4?username=<u>&token=<t>`.
  That final URL does not contain the password; from the server it answers
  a Cloudflare "Attention Required" `403`, from another address `206
  video/mp4` (`ftyp`), reusable for several range requests; the same host
  answers `https`. `HEAD` on the redirector answers `200` instead of
  redirecting, so the chain is walked with `GET`.
- Some items have only blocked progressive sources; some are dead
  (`404 text/html "No playable stream found."`). Episodes use
  `/series/<u>/<p>/<episode_id>.<ext>` and behave the same way.

## The probe

`Streamix.Iptv.Streaming.DeliveryProbe` tries an item's sources in the
provider's order — the `source_ids` the sync now stores for movies and
episodes, or `?source=1`, `2`, `3` until the next sync has stored them — at
most `XTREAM_PROBE_MAX_SOURCES` (6). Each source is walked by
`RedirectResolver.final_hop/2`:

- manual redirects, at most five; every hop, the first one included, passes
  the SSRF validator (private and loopback addresses refused) before it is
  requested;
- each hop is a `GET` halted as soon as the first body chunk arrives; only
  that chunk's first 16 bytes are kept, to recognise `#EXTM3U`. No body is
  read or stored;
- the first hop that does not redirect is the final hop, whatever its status.

The first usable source decides:

| Final hop | Decision |
| --- | --- |
| `200`/`206` with an HLS type (`application/vnd.apple.mpegurl`, `application/x-mpegurl`, `audio/mpegurl`) or an `#EXTM3U` prefix | HLS gateway, rooted at that source's `?source=N` URL |
| `200`/`206` media, or `401`/`403`, reached through at least one redirect, whose URL passes the safety gate | direct client, to that URL |
| `404`/`410`, `5xx`, a web page (`text/html`, JSON, XML), the panel itself answering without a redirect, an unsafe or credential-bearing URL, a transport error | next source |

No usable source → `404 upstream_not_found` when every source answered
`404`/`410`, otherwise `502 upstream_unavailable`.

Decisions are cached in ETS per provider (keyed with a hash of its URL,
username and password, so changed credentials never reuse a decision), item
type and stream id: HLS for `XTREAM_PROBE_HLS_TTL_SECONDS` (1800), direct for
`XTREAM_DIRECT_URL_TTL_SECONDS` (600 — the final URL embeds an upstream token,
and seeks and reconnects within it reuse one resolution), failures for
`XTREAM_PROBE_FAILURE_TTL_SECONDS` (120). Concurrent first requests for an
item share one probe; a probe runs under the provider's HLS fetch lease and
an overall `XTREAM_PROBE_DEADLINE_MS` (20000) → `504 upstream_timeout`. The
cache is node-local.

## The safety gate (`Streamix.Iptv.Streaming.DirectUrl`)

Before a URL is ever handed out:

- it must be `http`/`https` with a host and without userinfo;
- it must not contain the provider's decrypted password, raw,
  percent-encoded or percent-decoded; a provider redirect that keeps the
  password in the URL is skipped, never forwarded;
- `http` is upgraded to `https` and an explicit `:80` dropped (another
  explicit port is kept).

The URL may still carry the account username and a short-lived CDN token —
the accepted cost of this mode. It is never logged: the probe logs only the
provider id, item id and failure atoms, and every walk helper avoids URLs.

## Route and URL contract

`GET`/`HEAD`/`OPTIONS /api/stream/vod/direct.<container>?token=…`:

1. the signed movie/episode token is authorized exactly like the progressive
   flow (signature, two-hour age, ownership/visibility, subscription policy,
   API-key bypass), then the provider's `is_active` (`503 provider_disabled`)
   and health (`503 provider_degraded`). A refused request never probes;
2. the cached or fresh probe must have decided "direct"; an item it sends to
   the HLS gateway answers `409 stream_format_mismatch`;
3. the response is `302` with `Location: <final URL>`,
   `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, CORS headers,
   and no body. `HEAD` answers the same redirect.

Minting asks `Streamix.Playback.xtream_route/4`, which probes (or reuses the
cached decision) for flagged providers, so the suffix always matches what the
client receives: `.m3u8` (the HLS gateway) or `.<container>` (the direct
route, named after the final URL's extension, else the catalogue's, else
`mp4`). This applies to catalog `stream_url` and `browser_stream_url`,
`/api/v1/catalog/{movies,episodes}/:id/stream`, and the watch page. The
direct route is never wrapped in the browser stream proxy
(`source.mahina.fun`): that proxy's egress is a server address the CDN
refuses, and it would log the CDN URL with its username and token. A player
holding an older `/api/stream/proxy?token=…` URL is redirected to the route
the probe picks, or gets the probe's error (`404 upstream_not_found` for a
dead item). The next-episode preload does not probe; it uses a cached
decision or the proxy URL. Unflagged providers and their items are
unchanged.

The cost of minting from a probe: the first catalog detail, stream endpoint
or watch-page start for an item of a flagged provider waits for its probe
(about a second per source walked, bounded by the deadline); later ones within
the TTL read the cache.

## Players

- **Web player.** `.mp4`/`.mkv` select the native `<video>` engine, and
  neither the `<video id="video-element">` element nor the native engine sets
  `crossorigin`, so the element follows the cross-origin `302` and plays the
  CDN response without needing CORS from it. No change is needed. The
  AVPlayer (libmedia WASM) and mpegts.js fallback engines fetch with
  JavaScript and would need CORS headers from the CDN, which it is not known
  to send, so a direct item depends on native playback; the player's
  `proxyUrl` for the direct route is the route itself, never the stream
  proxy.
- **TV app.** AVPlay and the HTML5 backend receive the direct URL from the
  catalog API and follow the redirect from the viewer's own address. Not
  verified on hardware.

## Data and configuration

- Migration `20261012215254_add_xtream_delivery_probe_fields`:
  `providers.direct_client_playback boolean not null default false`
  (operator-only: cast by the admin changeset, never by `user_changeset/2`),
  and nullable `movies.source_ids` / `episodes.source_ids integer[]`, filled
  by the VOD and series syncs from each item's `sources`.
- Turning the mode on for a provider:
  `Streamix.Providers.update_provider(provider, %{direct_client_playback: true})`.
- `config :streamix, :xtream_delivery` (see `config/runtime.exs`).

## Deterministic checks

```sh
mix test test/streamix/iptv/streaming/delivery_probe_test.exs \
  test/streamix_web/controllers/xtream_direct_controller_test.exs \
  test/streamix/iptv/sync/normalizers_test.exs \
  test/streamix/iptv/sync/episode_upsert_preservation_test.exs
```

`Req.Test` fixtures cover the measured chain (panel → redirector → final CDN
answering `403` to the server), `GET` on every hop, `http` → `https` with `:80`
dropped, HLS recognised by type and by body prefix, source order with dead
sources skipped, episodes on `/series/`, refusal of a password-bearing final
URL and of the panel's own URL, SSRF on a redirect hop, the hop limit, the
dead-item `404`, cache reuse, single-flight, expiry and credential rotation,
token and provider refusals without a probe, unflagged providers untouched,
minted URLs on every surface, the proxy redirect, the owner changeset, and
log lines free of the password, username, token and CDN host.
