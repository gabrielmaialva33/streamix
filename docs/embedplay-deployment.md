# Embedplay resolver deployment

The resolver runs as a separate Compose project from the application. The main
deployment's `--remove-orphans` must not remove it. It shares `shared_network`
with Streamix and publishes no host port. Keep the application and resolver on
the same egress IP because upstream media can bind playback to that IP.

## Build and start

Build `services/embedplay-resolver/Dockerfile` with that directory as its build
context. The Playwright image is pinned by digest and matches `package-lock.json`.
Copy `deploy/docker-compose.embedplay.yml` and `deploy/embedplay-seccomp.json`
into the same deployment directory on the Docker host.

Prepare a mode-0600 resolver environment file containing a freshly generated
`EMBEDPLAY_RESOLVER_SECRET` of at least 32 bytes. Never copy the application
environment file into the resolver. Set these non-secret options alongside it:

```dotenv
EMBEDPLAY_RESOLVER_CONCURRENCY=2
EMBEDPLAY_RESOLVER_TIMEOUT_MS=45000
```

Set `EMBEDPLAY_RESOLVER_IMAGE` to the built image and
`EMBEDPLAY_RESOLVER_ENV_FILE` to the absolute private environment file path.
Then run Compose with `-f docker-compose.embedplay.yml up -d --wait`.
Do not render expanded Compose configuration into shared logs: it contains
the resolver secret. Use `config --quiet` for validation.

The container uses a non-root user, Chromium's sandbox, a read-only filesystem,
bounded temporary storage, two CPUs, a 2-GiB memory limit and bounded logs.
Its healthcheck expects an unauthenticated HTTP 401 after browser warmup.

The seccomp profile comes from
[Playwright v1.63.0](https://github.com/microsoft/playwright/blob/v1.63.0/utils/docker/seccomp_profile.json).
One rule is adjusted: `chroot` is allowed independently of the container's
capability list. Chromium needs it inside its own user namespace when all
container capabilities have been dropped. Kernel capability checks still apply;
neither `SYS_ADMIN` nor `--no-sandbox` is used. See the
[Playwright Docker guidance](https://playwright.dev/docs/docker).

## Application configuration

Back up the current application environment file with mode 0600 before editing.
Use the same resolver secret in the application and set:

```dotenv
EMBEDPLAY_ENABLED=true
EMBEDPLAY_RESOLVER_URL=http://streamix-embedplay-resolver:4010
EMBEDPLAY_RESOLVE_TIMEOUT_MS=60000
EMBEDPLAY_SESSION_TTL_SECONDS=600
```

The backend deadline exceeds the resolver's 45-second deadline. Never expose the
private resolver or its secret in catalog responses.

Check paused Oban queues before restarting the application. Queue pauses are
runtime state and can disappear on restart. In the September 14 activation,
`tmdb_details` was intentionally paused, so the existing `:embedplay` application
configuration was updated through the release RPC without restarting Streamix.
The environment file was also saved for the next normal deployment.

An in-place RPC update does **not** change the Docker container's original
environment. A restart of that same container loses the RPC update; a Compose
recreation reads the saved environment. Coordinate the next deployment with the
enrichment fix before allowing the paused queue to resume.

## Playback validation and catalog

Follow [the one-movie import](embedplay-catalog.md) first. Test the signed Streamix
gateway with a real HLS player, including segment loading and seeking. Keep all
signed URLs in private temporary files and remove them after testing. Check a
second master request to measure cache reuse separately from first resolution.

Only then enqueue the full inventory sync. It imports IDs and schedules TMDB
details; it does not resolve every film. If `tmdb_details` is paused, full catalog
metadata will wait too. Do not unpause unrelated enrichment jobs to validate this
provider. A single canary can be enriched through `Streamix.Catalog.fetch_movie_info/1`.

## September 14, 2026 validation

Production smoke used one confirmed movie, with an isolated Chrome/HLS.js player
fetching only the public signed Streamix gateway. Playback reached 1920×1080,
advanced past two seconds, and sought past 122 seconds. All six observed media
responses returned HTTP 200; no media request went to another origin.
First playback took 23.516 seconds including resolution and buffering; a later
master request reused the backend cache and returned in 352 ms. These are single
smoke measurements, not latency percentiles or physical-TV validation.
Authenticated catalog provider, movie detail and movie stream requests also
returned HTTP 200. The provider appeared in the list, and both detail stream URL
fields pointed to the signed Embedplay gateway.
The full inventory sync completed with 9,424 movies. Metadata jobs remain in the
intentionally paused `tmdb_details` queue, apart from the manually verified canary.

The resolver's 20 tests passed. `mix precommit` passed with 1,461 checks
(1,456 tests and five doctests), 26 excluded, before the separate enrichment
work began changing the shared tree. The main production Compose contract also
passed unchanged. The application was not restarted and `tmdb_details` remained
paused throughout activation.

## Rollback

Disable `:embedplay` in the running application and set `EMBEDPLAY_ENABLED=false`
in its persistent environment. Deactivate the Embedplay provider through
`Streamix.Providers.update_provider/2` to hide imported cards. Retain catalog,
favorites and history records. Stop the separate resolver Compose service after
new playback has been disabled. No schema rollback or data deletion is needed.

If restoring an environment backup, first check for newer unrelated edits.
Restore only this activation's keys when another operator has changed the file.
