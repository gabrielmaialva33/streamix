# Embedplay resolver (private service)

Movie-only, on-demand adapter for Streamix. It drives the public Embedplay selector
with an isolated context in a shared Playwright Chromium process, selects the requested language and
BYSE, and validates the HLS master referenced by the content player's public
`jwplayer().getPlaylistItem()` API. It does not ingest catalogs, persist media URLs,
solve human challenges, or serve media to TV clients.

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
`dubbed` and `subtitled` are valid audio values. The current adapter resolves only
BYSE by its server name, independently of its displayed option number; if the
selected language has no BYSE option it fails, without falling back to
a different language. No caller-supplied URL or additional input keys are accepted.
The request body limit is 2 KiB.

The movie inventory is not a promise that this adapter supports every listed
movie. On September 14, 2026, a production-host inspection of TMDB 10010 found
only dubbed ABYS and UPNS options, with no BYSE option. The ABYS document returned
HTTP 403. UPNS exposed a configured HLS source through its Vidstack player, but
that source returned HTTP 404 both when the player loaded it and when fetched
independently. The browser probes used this resolver's service-worker-disabled
context; a virtual URL served by a service worker is not ruled out by that 404.
No standalone HTTP manifest was validated for UPNS. Neither path was validated as
a fallback. These observations are
specific to that movie, time and host; they do not establish catalog-wide
availability or success rates. Retrying the BYSE selector cannot add a missing
server. This adapter still supports only the verified BYSE path.

Success is a JSON object containing `manifest_url` (private upstream URL),
`expires_at: null`, and `headers: {}`. The unknown expiry must not be interpreted as
permanent validity. The master is independently fetched without cookies, Referer,
or browser headers; sources requiring those credentials are unsupported. URLs,
tokens, and this response must never be logged or returned directly to a browser.
Phoenix must return its signed StreamToken-backed gateway URL instead.

Errors use `{"error":{"code":"..."}}`; no upstream error messages are included.

| HTTP | Code |
| --- | --- |
| 400 | `invalid_request` |
| 401 | `unauthorized` |
| 404 | `not_found` |
| 502 | `stream_unavailable`, `challenge_required` |
| 503 | `busy`, `resolver_unavailable` |
| 504 | `resolution_timeout` |

Every response has `Cache-Control: no-store`; `busy` also has `Retry-After: 5`.
No unauthenticated health endpoint is exposed.

## Resolution and network boundaries

- The entry origin is fixed. Document navigation is restricted to the observed
  Embedplay/BYSE/player hosts; host changes fail closed and require review.
- Each browser generation uses an ephemeral local HTTPS CONNECT proxy. Every socket resolves DNS,
  rejects non-public addresses, and connects to the checked address directly,
  avoiding a check/use DNS-rebinding gap. HTTP and non-443 destinations are denied;
  Chromium's loopback proxy bypass, QUIC and non-proxied WebRTC UDP are disabled.
- Service workers, downloads and popup pages are disabled/closed. Only the observed
  `disable-devtool` script is skipped; no CAPTCHA or DRM circumvention is present.
- A candidate must originate from the selected BYSE descendant player frame,
  match that JW content item's source URL exactly, and parse as an HLS master.
  This rejects unrelated sibling-frame and same-frame ad manifests. Embedded
  advertising inside the actual content playlist is not removed.
- Validation streams at most 256 KiB, pins public DNS, rejects redirects, and sends
  no browser credentials. Media playlists and segments are not returned as masters.
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

The 20 tests use real headless Chrome and fully intercepted local fixtures (no Embedplay
requests). They cover nested frames and clicks, same-frame and sibling ad rejection,
HLS master selection, challenges, explicit language behavior, deadline cleanup,
public-IP policy, request authentication, sanitized errors, capacity and singleflight.
Pool tests also cover cookie isolation, reuse, graceful retirement, crash recovery,
late acquisition cancellation, concurrent timeouts and sanitized timing records.

Manual smoke on 2026-09-09: movie 852854, dubbed/BYSE, resolved a verified master
using this service implementation in approximately 11 seconds, with no cookies or
Referer and unknown expiry. This checks one title from the workstation's IP;
server-IP behavior, wider title coverage and physical TV playback remain separate
integration checks. No signed URL is stored in this repository.

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
`entry_loaded_ms`, `selector_ready_ms`, `language_selected_ms`, `provider_selected_ms`,
`content_candidate_ms`, `manifest_verified_ms` and `total_ms` (including cleanup).
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
