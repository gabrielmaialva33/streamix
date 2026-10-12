# Embedplay resolver (private service)

Movie-only, on-demand adapter for Streamix. It drives the public Embedplay selector
with an isolated context in a shared Playwright Chromium process, selects the requested
language and a supported server (currently ABYS), and returns the media URL that the
content player's public `jwplayer()` API identifies, after verifying it independently:
a progressive MP4 for ABYS, an HLS master for HLS providers. It does not ingest catalogs,
persist media URLs, solve human challenges, or serve media to TV clients.

## Run locally

For the isolated production container, see
[the deployment runbook](../../docs/embedplay-deployment.md).

Node 22+ and Chromium/Chrome with its sandbox available are required. Dependencies
are exact-pinned in `package-lock.json`.

```sh
npm ci --prefix services/embedplay-resolver
export EMBEDPLAY_BROWSER_EXECUTABLE=/usr/bin/google-chrome-stable
# Supply a private random secret of at least 32 bytes through your secret manager.
# The Phoenix EMBEDPLAY_RESOLVER_SECRET must equal the secret supplied here.
node services/embedplay-resolver/src/server.js
```

Set `EMBEDPLAY_RESOLVER_SECRET` before starting. The service refuses to start without
it. With no executable path, Playwright uses its installed managed Chromium;
install it explicitly with `npx playwright install chromium` from this directory.
Do not disable the browser sandbox to fix missing host prerequisites.

| Environment | Default | Purpose |
| --- | --- | --- |
| `EMBEDPLAY_RESOLVER_SECRET` | Required | Bearer shared secret, at least 32 bytes |
| `EMBEDPLAY_RESOLVER_HOST` | `127.0.0.1` | Private listening interface |
| `EMBEDPLAY_RESOLVER_PORT` | `4010` | Listening port |
| `EMBEDPLAY_BROWSER_EXECUTABLE` | Playwright Chromium | Chrome/Chromium executable |
| `EMBEDPLAY_RESOLVER_TIMEOUT_MS` | `30000` | Resolution deadline, 1000–45000 ms |
| `EMBEDPLAY_RESOLVER_CONCURRENCY` | `2` | Maximum isolated contexts, 1–2 |
| `EMBEDPLAY_BROWSER_MAX_JOBS` | `100` | Resolutions before draining and recycling Chromium, 1–10000 |

Point Phoenix's trusted `EMBEDPLAY_RESOLVER_URL` configuration at this private
service. Its HTTP deadline must exceed the resolver deadline. There is no waiting
queue: two distinct resolutions may run, further distinct work gets `503 busy`.
Concurrent calls for the same canonical identifier and audio share one resolution.
The Node service does not cache results because their expiry is unknown; Phoenix
separately reuses verified sessions for ten minutes when starting playback. A disconnected client may
leave that shared resolution running, bounded by its deadline; it never leaves
queued jobs. Run the resolver near the media gateway with the same egress IP.

This service is opt-in and uses its own production Compose project. Its container
uses a non-root user and a Chromium-compatible seccomp policy; never mount host
credentials or a real browser profile. Docker on the development workstation uses
a remote context: published ports and bind mounts are on that remote host, not the
workstation. Do not start the local daemon implicitly.

## Private API

`POST /resolve`, `Authorization: Bearer <shared secret>`,
`Content-Type: application/json`:

```json
{"tmdb_id":852854,"audio":"dubbed"}
```

`tmdb_id` accepts a positive integer or decimal string. Alternatively pass
`imdb_id` such as `tt1234567`; when both are present TMDB is authoritative. Only
`dubbed` and `subtitled` are valid audio values. The adapter picks a supported
server by its name in the selector's `Opção N (NAME)` label, never by the
displayed number, and only among the options shown for the requested language;
it never falls back to a different language. No caller-supplied URL or additional
input keys are accepted. The request body limit is 2 KiB.

Supported providers are an explicit table in `src/resolver.js` (`PROVIDERS`):

| Server | Kind | Embed host | Player host | Forwarded headers |
| --- | --- | --- | --- | --- |
| ABYS | `mp4` | `embedplayabyss.top` | `abysscdn.com` | `user-agent`, `referer` |

`KNOWN_UNSUPPORTED` lists names that are recognized but deliberately not driven:
BYSE (still listed for some titles, but its player host rotated from
`f7hyg4q.org` to `n1mwq.org`, so no stable allowlist entry exists), UPNS and LOAD
(different players), an option without a server name, and the `Legendado (EUA)`
third-party embed. The HLS path (`kind: "hls"`) remains implemented and tested for
a future provider entry.

The movie inventory is not a promise that this adapter supports every listed
movie. A static sample of 180 ids from `https://embedplayapi.top/api/all-ids` on
2026-10-12 found 160 selector pages (18 requests were rate limited, 2 titles
redirected to `/404.php`): 150 offered both languages, all with a dubbed ABYS option
and 4 also with a subtitled one; 10 were subtitled-only ("Disponível Apenas
Legendado"); 24 also listed BYSE. A listed ABYS option is not a playable one either:
some titles carry only service-worker decoy sources (see "Content, not
advertising"), and they resolve to `stream_unavailable`. The 403 that a
September 14, 2026 inspection of TMDB 10010 recorded for the ABYS document was
Cloudflare's managed challenge to Chromium's headless User-Agent (measured on
2026-10-12: `cf-mitigated: challenge`, `X-Frame-Options: SAMEORIGIN`). The resolver
keeps Chromium's own User-Agent and does not alter its identity to avoid bot
detection, so while abysscdn.com keeps that rule every ABYS resolution ends as
`challenge_required` (see "Verification").

Success is a JSON object:

```json
{"kind":"mp4","media_url":"https://…","expires_at":null,
 "headers":{"referer":"https://abysscdn.com/","user-agent":"<the browser's own User-Agent>"}}
```

- `kind` is `mp4` (progressive) or `hls`. An `hls` answer also carries
  `manifest_url`, equal to `media_url`, for Phoenix releases that read only that
  field; an `mp4` answer deliberately omits it, so such a release fails cleanly
  instead of parsing an MP4 as a playlist.
- `media_url` is the URL the content player requested, not where it redirects:
  ABYS answers with a 302 to an ephemeral `*.trycloudflare.com` tunnel, which Phoenix
  follows itself (at most five SSRF-validated hops).
- `headers` has lowercase keys drawn only from `user-agent` and `referer`: exactly
  what the player sent to that URL and what the independent check below used.
  Never cookies, `Authorization` or `Origin` (an `Origin` makes the ABYS media
  host answer 404).
- `expires_at` is `null`: the expiry is unknown and must not be read as permanent
  validity.

Referer-dependent sources are supported, with Referer only. ABYS media answers 403
(a Cloudflare hotlink page) without `Referer: https://abysscdn.com/` and 206 with it;
no cookie is involved. Replaying that header is safe because it is not a credential:
it is a public origin string the browser sends to every such request, it grants
nothing beyond the URL itself, and it carries no session, account or cookie state.
The resolver checks it is an `https` URL on the provider's own player host before
using it. URLs, tokens and this response must never be logged or returned directly
to a browser; Phoenix returns its signed StreamToken-backed gateway URL instead.

Errors use `{"error":{"code":"..."}}`; no upstream error messages are included.

| HTTP | Code |
| --- | --- |
| 400 | `invalid_request` |
| 401 | `unauthorized` |
| 404 | `not_found` |
| 502 | `stream_unavailable`, `challenge_required`, `unsupported_page` |
| 503 | `busy`, `resolver_unavailable` |
| 504 | `resolution_timeout` |

`stream_unavailable` means the page is one the adapter knows, but this title gave
no verified source: an unknown title (entry "Filme ou episódio não encontrado" or
the selector's `/404.php`), an upstream error status, the requested language not
offered, only known-unsupported servers for it, a content player that ended in its
`error` state with nothing left to verify, or a candidate that failed verification.
`unsupported_page` means the page loaded but no longer matches what the adapter can
drive, so the adapter needs review: no language control, no option shown within
`structureMs` (6 s, after trying `Mostrar Opções`), a shown server name outside both
tables with no supported one beside it, or the entry or selected provider framing a
host outside the allowlist. It is never used for a single title lacking a source.
`challenge_required` covers a visible challenge text and any document answered with
`cf-mitigated: challenge`, including one that may not be framed and so never
renders; it is reported as soon as that document arrives, not at the deadline.

Every response has `Cache-Control: no-store`; `busy` also has `Retry-After: 5`.
No unauthenticated health endpoint is exposed.

## Resolution and network boundaries

- The entry origin is fixed. Document navigation is restricted to an explicit host
  allowlist: `embedplayapi.top`, `embedplay.one`/`www.embedplay.one`, and each
  supported provider's embed and player hosts (today `embedplayabyss.top` and
  `abysscdn.com`). Any other host is refused and, in the entry or the selected
  provider's frames, reported as `unsupported_page` for review. Subresources
  (media hosts such as `*.sssrr.org` and its `*.trycloudflare.com` redirect target,
  scripts, images) keep the previous rule: HTTPS on port 443 without userinfo only.
- Each browser generation uses an ephemeral local HTTPS CONNECT proxy. Every socket resolves DNS,
  rejects non-public addresses, and connects to the checked address directly,
  avoiding a check/use DNS-rebinding gap. HTTP and non-443 destinations are denied;
  Chromium's loopback proxy bypass, QUIC and non-proxied WebRTC UDP are disabled.
- Service workers, downloads and popup pages are disabled/closed. Service workers
  must stay blocked: with them, the ABYS player's `<video>` source is a
  `storage.googleapis.com/mediastorage/…` decoy served by a worker
  (`abysscdn.com/sw.import.js`), and the same URL answers 403
  `UserProjectAccountProblem` outside the browser. Only the observed
  `disable-devtool` script is skipped; no CAPTCHA or DRM circumvention is present.
- Contexts keep Chromium's own User-Agent. The resolver does not change its
  identity, run headed or under a virtual display, patch fingerprints or use stealth
  plugins to avoid bot detection; that is the same category as solving a challenge.
  The `user-agent` it returns is the one the browser sent with the media request.
- Options are chosen as a person would see them: shown (not `display:none`, not
  `visibility:hidden`, opacity ≥ 0.99 through its ancestors, not clipped by an
  `overflow` box), settled for two consecutive reads, in the requested language.
  Playwright's own visibility test counts the inactive language group (opacity 0,
  clipped) as visible, so a bare text locator could pick another language's option.
  `Mostrar Opções` is pressed only when no option is shown.
- Content, not advertising: a candidate must be a request from the selected
  provider's player frame (player host, below its embed host, below the selector
  frame this resolution drove), not a redirect hop, of the provider's kind (`media`
  for MP4, `xhr`/`fetch` for HLS), equal to the JW content item's `file` or one of
  its `sources` resolved against the document and, for MP4, also the `currentSrc` of
  the `<video>` inside `jwplayer().getContainer()`. Verified live on 2026-10-12 with
  service workers blocked (TMDB 1576 and 9502): the item first lists
  `storage.googleapis.com` decoys that the `<video>` requests and Chromium blocks
  (ORB), then the player swaps the item to protocol-relative `sssrr.org` sources;
  the requested 360p URL then equals `item.file` and the container's only
  `<video>`'s `currentSrc`. The playlist had one item and no `advertising` block, and
  the media reported the feature's runtime (6022 s for the 2002 movie). Decoys pass
  this check too, which is why independent verification is the gate. Titles whose
  item holds only decoys leave the player in its `error` state with an empty
  playlist (TMDB 59859, 57876, 494493 on 2026-10-12); after one second in that state
  with nothing left to verify the resolution ends as `stream_unavailable`.
  Sibling-frame and same-frame advertising videos and playlists are rejected.
  Embedded advertising inside the actual content media is not removed. These player
  observations were made while investigating, with a non-headless User-Agent that
  the resolver does not use; with its own User-Agent the player is currently not
  served at all (see "Verification").
- MP4 verification fetches `media_url` outside the browser with only the headers
  that will be returned plus `Range: bytes=0-1023`, follows at most five redirects
  (each hop again HTTPS on 443, without userinfo, with every DNS answer public and
  the socket pinned to it), reads at most 1 KiB even if `Range` is ignored, and
  accepts only 200/206 `video/mp4` or `application/octet-stream` whose bytes 4..8 are
  the ISO-BMFF `ftyp` box. Transport failures are retried twice, since each request
  reaches a fresh tunnel. HLS verification is unchanged: one response, no redirects,
  at most 256 KiB, a master playlist with a variant URI.
- Each resolution closes its context on success, error and timeout. Chromium and
  its proxy remain warm until recycling or service shutdown. A timeout does not
  close other resolutions. Normal operation writes no request, response, URL, token, browser-console or
  Playwright exception logs. Do not enable Playwright `DEBUG`, tracing, HAR capture,
  screenshots or an HTTP body logger on production traffic.

## Verification

```sh
EMBEDPLAY_BROWSER_EXECUTABLE=/usr/bin/google-chrome-stable \
  npm test --prefix services/embedplay-resolver
```

The 43 tests make no network requests. Browser tests use real headless Chrome with
every request answered by local fixtures modelled on the 2026-10-12 page: padded
labels, collapsed options behind `Mostrar Opções`, an opacity-0 clipped inactive
language group, the subtitled-only layout, a click-trap overlay, a JW item that
lists a decoy before the content source, and same-frame and sibling advertising.
They cover ABYS selection by server name, both contract shapes (MP4 without
`manifest_url`, HLS with it), the exact forwarded headers, every `unsupported_page`
and `stream_unavailable` classification above, visible challenges and a Cloudflare
managed challenge served (unframeable) to Chromium's default User-Agent, which must
end as `challenge_required` within seconds, failed MP4 verification, deadline
cleanup, sanitized timing records, concurrency and singleflight. Network tests use
injected DNS and HTTPS fakes to cover redirect following, per-hop public-address
checks, the five-redirect bound, header filtering, hotlink HTML, `Range` being
ignored and the `ftyp` check. Pool tests cover cookie isolation, the unmodified
User-Agent, service-worker blocking, reuse, retirement, crash recovery and
late-acquisition cancellation.

Live check on 2026-10-12 from the workstation (residential IP), through
`node src/server.js` with a random 32-byte secret, a prewarmed browser and
Chromium's own User-Agent:

| Request | Result | ms |
| --- | --- | --- |
| TMDB 1576 (Resident Evil, 2002), dubbed | `challenge_required` | 3027 |
| IMDb tt0120804 (same movie), dubbed | `challenge_required` | 3420 |
| TMDB 9502, dubbed | `challenge_required` | 3104 |
| TMDB 802194, dubbed | `challenge_required` | 3612 |
| TMDB 47964, dubbed | `challenge_required` | 3558 |
| TMDB 1186830 (subtitled-only page), subtitled | `challenge_required` | 2989 |
| TMDB 615453 (subtitled-only page), subtitled | `challenge_required` | 2989 |
| TMDB 1186830, dubbed | `stream_unavailable` (language not offered) | 1362 |
| TMDB 999999999, dubbed | `stream_unavailable` ("Filme ou episódio não encontrado") | 880 |

Every ABYS title reached the selector, chose ABYS for the requested language and
then received abysscdn.com's managed challenge about 0.7 s later; that is the
expected outcome while abysscdn.com challenges headless Chromium, and the resolver
does not work around it. Playwright 1.63's bundled chrome-headless-shell, which the
container uses, gave the same result for TMDB 1576, 9502 and 615453 (2.9–3.6 s).
No ABYS media URL was obtained with this configuration, so no independent media
fetch or URL lifetime is recorded here. This checks the workstation's IP only;
production-host behaviour may differ. No resolved URL is stored in this repository.

Public API references used by the adapter:
[Playwright Response](https://playwright.dev/docs/api/class-response),
[JW Player playlist item](https://docs.jwplayer.com/players/reference/getplaylistitem_index_),
[JW Player source fields](https://docs.jwplayer.com/players/reference/playlist-events).


## Browser lifecycle and performance

The executable starts one sandboxed Chromium before accepting requests. Each job
gets a fresh nonpersistent context; neither cookies nor pages are shared. Closing
a job releases only its context. After `EMBEDPLAY_BROWSER_MAX_JOBS` acquisitions,
new work receives `503 busy` while remaining contexts drain; then Chromium and its
proxy close. The next job starts the replacement. Browser crashes follow the same
cleanup path, with relaunch on the next acquisition. SIGINT/SIGTERM stop accepting
HTTP requests, drain active requests and close the pool; a hard shutdown deadline
bounds cleanup. Library callers must call `resolve.close()` during shutdown and
can call `resolve.warmup()` before serving traffic.

The service emits one JSON timing record per actual resolution, including failures.
Records contain only a fixed event name, a sanitized outcome and numeric elapsed
milliseconds from resolution start. No content IDs, URLs, headers, tokens or raw
errors are included. Milestones are `context_ready_ms`, `page_ready_ms`,
`entry_loaded_ms`, `selector_ready_ms`, `language_selected_ms`, `options_expanded_ms`
(only when `Mostrar Opções` was pressed), `options_ready_ms`, `provider_selected_ms`,
`player_frame_ms`, `content_candidate_ms`, `media_verified_ms` (named
`manifest_verified_ms` before progressive MP4 support) and `total_ms` (including cleanup).
Unreached milestones are omitted. These are cumulative offsets, not per-stage
durations; subtract adjacent milestones for stage duration. Group successful and
failed resolutions separately when computing p50/p95. Cache hits and coalesced
callers do not generate new resolution records. Routing still disables Chromium's
HTTP cache, so browser reuse alone does not imply reuse of static assets.

Two sequential direct resolver calls on 2026-09-09 used one prewarmed browser and
resolved the same dubbed BYSE movie successfully in 14.014 s and 12.466 s. Context
plus page initialization reached 43 ms and 45 ms. The interval from BYSE selection
to the first verified content candidate was 9.557 s and 8.357 s, followed by 1.164 s
and 0.987 s for independent manifest validation. This small workstation sample
locates most waiting after provider selection; it is not a production percentile
or evidence of an end-to-end speedup over the earlier 11.2 s smoke. Upstream expiry
remains unknown. HTTP-first resolution and TV intent-based prefetch are subsequent
work, not implemented by this pool change.

In the 2026-10-12 live check above the page part was steady: selector ready at
1.35–1.42 s, language selected at 1.9–2.6 s (subtitled-only pages skip the click),
ABYS selected at 2.2–2.9 s, and the challenge reported 0.7 s later, so a challenged
title costs about 3 s rather than the 30 s deadline.
