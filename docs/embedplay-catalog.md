# Embedplay movie provider

Embedplay is an experimental, opt-in provider. This first delivery imports **movies only**.
The index exposes IMDb/TMDB IDs; it does not provide an episode inventory. Series and live
channels are intentionally unsupported until their availability contract is verified.

## Activation and one-movie validation

Apply database migrations and configure the private browser resolver before enabling
`EMBEDPLAY_ENABLED=true`. No catalog crawl runs at startup; once enabled, a daily cron
(06:43 UTC) refreshes the inventory, and is skipped while resolution is degraded (see
[Resolution health](#resolution-health)). Activation alone does not import any content. See [the playback documentation](embedplay-playback.md) for the resolver
and the progressive MP4 / HLS playback gateway. Imported movies record `container_extension`
`mp4`, which the web player uses to choose native progressive playback.

From an application console, import a movie whose availability you have confirmed:

```elixir
{:ok, movie_id} = Streamix.Embedplay.import_movie(603, "tt0133093")
```

This creates the system provider if needed, imports one movie, and enqueues its existing TMDB
details worker. It does not launch the embed page or resolve a stream. The regular movie detail
and stream endpoints then use the provider's playback resolver when playback is requested.
The optional IMDb argument can be omitted when only the TMDB ID is known.

For an explicit full movie inventory sync:

```elixir
{:ok, job} = Streamix.Embedplay.enqueue_sync()
```

The worker uses the documented fixed endpoint `https://embedplayapi.top/api/all-ids?type=movie`.
`Streamix.Embedplay.sync_catalog/0` is also available for a synchronous operator invocation.
Do not use the full inventory sync to validate the initial playback path.

## Identity and synchronization

- `provider_type` is `embedplay`; the public provider capability is `movies` only.
- The API accepts `provider_type=embedplay` on catalog filters.
- The numeric TMDB ID is the stable source `stream_id`, scoped to this provider. Existing
  `tmdb_id` and optional `imdb_id` columns support metadata enrichment and source equivalence.
- Unsupported/malformed rows, including IMDb-only entries, are counted as skipped. No title or
  episode availability is invented from a series ID.
- The initial display name is a TMDB identifier until the existing metadata worker fills the
  title, images, synopsis, and other details. Import does not copy metadata from unrelated rows.
- Repeat sync preserves the movie ID, catalog item, metadata, enrichment timestamps, favorites,
  and history. Provider-row locking serializes overlapping initial imports. A partial unique
  index prevents duplicate system-provider bootstrap.
- Empty, malformed, redirect, or failed upstream responses never delete existing movies.
  Missing movies remain until an explicit availability/removal policy is implemented.
- Ingestion stores no embed page URL, iframe URL, manifest URL, cookie, or media token in a movie.
- The source's `status` response is not a guarantee of media playback; resolution can still fail.

## Resolution health

Every playback start is observed by `Streamix.Embedplay.Health`. When resolution is
systematically failing, the system provider is marked **degraded** in
`providers.health_status` (with `degraded_at` and `degraded_reason`):

- its movies drop out of every browse surface — browse API, home shelves, search, ranked
  hydration and the provider directory — through `Streamix.Iptv.Access.browsable/2`;
- new playback fails at once with `503 provider_degraded` instead of waiting several seconds
  for a browser resolution that cannot succeed;
- the daily catalog sync is skipped, so no more unplayable titles are imported.

A direct lookup of a title still resolves, so favorites and history lead to that explicit error
rather than to a missing page. `is_active` is never touched: it remains the operator's switch,
and automatic recovery never re-enables a provider that was turned off on purpose.

Trip rules, over a six-hour window with no success in between (any success resets the streak):

| Resolver result | Trips after | Why |
| --- | --- | --- |
| `resolver_outdated` | 2 distinct titles | The page no longer has the structure the resolver drives — a site change, not a title |
| `no_source_available` | 5 failures over 5 distinct titles | Can be one title without a source; five distinct misses in a row is not |
| `challenge_required` | 5 failures over 5 distinct titles (shared with the row above) | The upstream challenged the resolver's browser; it is never solved or evaded, and challenges can be sporadic |
| timeout, capacity, generic failure | never on their own | Transient |

Recovery is automatic. `Streamix.Workers.EmbedplayCanaryWorker` runs at :17 and :47 past every
hour and resolves one random title (skipping ones that just failed). While degraded it probes on
every tick and the first success restores the catalog. While healthy it probes only after an
hour without any observed resolution, so a breakage is still caught when nobody is watching and
right after a deploy. Only one probe is ever in flight.

The trip logs a `warning` and the recovery an `info` line, both prefixed `[Embedplay]` with the
reason and counts. `Streamix.Embedplay.health/0` returns the persisted state and a summary of
the window, and `/api/health/ready` reports `checks.embedplay`.

Thresholds are application configuration (`config/config.exs`, `:embedplay`):
`health_window_seconds`, `health_window_size`, `health_trip_failures`, `health_trip_movies`,
`health_outdated_trip_movies` and `canary_idle_seconds`.

## Runtime configuration

| Environment variable | Default | Meaning |
| --- | --- | --- |
| `EMBEDPLAY_ENABLED` | `false` | Enable this integration; always false at test boot |
| `EMBEDPLAY_RESOLVER_URL` | unset | Private browser resolver base URL |
| `EMBEDPLAY_RESOLVER_SECRET` | unset | Shared secret, also configured on the resolver |
| `EMBEDPLAY_RESOLVE_TIMEOUT_MS` | `45000` | Backend resolution deadline, 1000–120000 ms |
| `EMBEDPLAY_SESSION_TTL_SECONDS` | `600` | HLS resolved-source reuse for new playback starts, 30–3600 seconds |
| `EMBEDPLAY_MAX_SESSIONS` | `128` | Per-process session bound, 1–1024 |
| `EMBEDPLAY_MAX_CONCURRENT_FETCHES` | `64` | Concurrent upstream fetches, 1–512; for MP4, roughly concurrent viewers |

This reuse window does not terminate active playback. A resource graph remains available
while used, with cleanup after 30 minutes of inactivity or an explicit upstream expiry.
An MP4 session is reused while alive regardless of the window, because every range request
of a progressive playback opens the movie again (see the playback documentation).
No upstream token lifetime is inferred from its URL.
Disabling the feature prevents new resolution, imports and full sync. To hide already imported
cards, deactivate its provider row as well.

## Validation and rollback

Tests use a fixed-host `Req.Test` fixture for inventory and sandboxed database records for
idempotency, metadata preservation, source identity, skipped entries and activation guards.
They never crawl the real inventory or consume a real stream.

The health columns (`health_status`, `degraded_at`, `degraded_reason`) are an additive
migration; code from the previous release ignores them.

The migration changes the provider CHECK constraint and adds a partial singleton index; it
rebuilds no media or history tables. Its rollback deliberately fails if Embedplay provider rows
remain, preserving data instead of silently deleting an imported catalog. Disable/deactivate
first, then explicitly migrate or remove retained provider data under a separate maintenance
plan before rolling back the schema.
