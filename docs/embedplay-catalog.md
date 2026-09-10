# Embedplay movie provider

Embedplay is an experimental, opt-in provider. This first delivery imports **movies only**.
The index exposes IMDb/TMDB IDs; it does not provide an episode inventory. Series and live
channels are intentionally unsupported until their availability contract is verified.

## Activation and one-movie validation

Apply database migrations and configure the private browser resolver before enabling
`EMBEDPLAY_ENABLED=true`. No catalog crawl runs at startup, and there is no automatic cron.
Activation alone does not import any content. See [the playback documentation](embedplay-playback.md) for the resolver
and HLS session gateway.

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

## Runtime configuration

| Environment variable | Default | Meaning |
| --- | --- | --- |
| `EMBEDPLAY_ENABLED` | `false` | Enable this integration; always false at test boot |
| `EMBEDPLAY_RESOLVER_URL` | unset | Private browser resolver base URL |
| `EMBEDPLAY_RESOLVER_SECRET` | unset | Shared secret, also configured on the resolver |
| `EMBEDPLAY_RESOLVE_TIMEOUT_MS` | `45000` | Backend resolution deadline, 1000–120000 ms |
| `EMBEDPLAY_SESSION_TTL_SECONDS` | `600` | Resolved-source reuse for new playback starts, 30–3600 seconds |
| `EMBEDPLAY_MAX_SESSIONS` | `128` | Per-process session bound, 1–1024 |

This reuse window does not terminate active playback. A resource graph remains available
while used, with cleanup after 30 minutes of inactivity or an explicit upstream expiry.
No upstream token lifetime is inferred from its URL.
Disabling the feature prevents new resolution, imports and full sync. To hide already imported
cards, deactivate its provider row as well.

## Validation and rollback

Tests use a fixed-host `Req.Test` fixture for inventory and sandboxed database records for
idempotency, metadata preservation, source identity, skipped entries and activation guards.
They never crawl the real inventory or consume a real stream.

The migration changes the provider CHECK constraint and adds a partial singleton index; it
rebuilds no media or history tables. Its rollback deliberately fails if Embedplay provider rows
remain, preserving data instead of silently deleting an imported catalog. Disable/deactivate
first, then explicitly migrate or remove retained provider data under a separate maintenance
plan before rolling back the schema.
