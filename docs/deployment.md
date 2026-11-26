# Deployment contract

Streamix deploys one application container on a VPS. The authoritative implementation is
[scripts/deploy-production.sh](../scripts/deploy-production.sh), invoked by the shared
[deploy action](../.github/actions/deploy-production/action.yml). The service definitions live in
[deploy/docker-compose.production.yml](../deploy/docker-compose.production.yml).

## Build, approve and deploy

The [main workflow](../.github/workflows/docker.yml) builds an immutable image, runs the backend, Dialyzer, frontend,
E2E and image-security gates, and promotes only an approved digest. Deployment consumes that digest, not a mutable tag.
The production environment and deployment concurrency serialize releases. The
[manual workflow](../.github/workflows/deploy-production.yml) uses the same deployment action.

The deployment script validates the digest and the supplied compose checksum before applying the versioned contract.
It retains the prior application image/compose state for rollback, recreates only `streamix` with `--no-deps`, and runs
readiness and application canaries. Read the script's current checks before changing deployment behavior;
`Streamix.DeployContractTest` protects the shared-infrastructure boundary. Never put credentials into the repository,
command output or incident reports.

## Shared infrastructure and recovery

An application deployment does not upgrade PostgreSQL, TimescaleDB, Redis, RabbitMQ or Qdrant. Changing an image in
compose is not permission to recreate shared infrastructure. Schedule those operations separately, back up first,
rehearse restore and rollback, and account for the other applications sharing the service. The exact operator procedure
for TimescaleDB extension upgrades and application restart is maintained in [AGENTS.md](../AGENTS.md).

[database-restore.md](database-restore.md) describes database recovery. Image rollback does not reverse a database
migration; schema changes need compatibility with the preceding application image or an explicit recovery procedure.
Persistent image/VOD caches live on the application data volume and have different recovery requirements from user data.

## Local validation is not a deployment

Run compilation, formatting, Credo, tests, Dialyzer and frontend checks before proposing a release. Use synthetic data and
test-only database/Redis endpoints. Inspect the Docker context before running container-based tools: with a remote
daemon, bind mounts and host networking refer to that host, not the developer's checkout or loopback interface.
Deployment credentials and production access are unnecessary for ordinary code validation. A passing local test suite
does not establish that production infrastructure has been upgraded or a release deployed.

The image resize cache admits two producers and 32 waiters per key, with a 60-second work deadline. Disk retention is lazy (on publication): 30 days, 512 MiB, 10,000 JPEGs by default. `StreamixWeb.Api.V1.ImageResizeController` config accepts `max_bytes`, `max_entries` and `ttl_seconds` alongside `cache_dir`. Publication and eviction are serialized; a cache miss scans the bounded directory. Monitor miss latency before increasing its entry budget.

Configure `TRUSTED_PROXY_CIDRS` as a comma-separated list of the actual reverse-proxy socket peers (for example loopback `/32` and `/128` only when that is the connection Phoenix sees). Empty means trust none. Do not trust an entire private network just to accommodate Docker. The proxy must overwrite X-Forwarded-For with a verified client address or append the actual peer to its chain; Streamix walks from right to left until the first untrusted address. CF-Connecting-IP and X-Real-IP are not identity authorities. If using Cloudflare, validate its peer at the edge and normalize X-Forwarded-For there, or explicitly maintain all trusted hops. Malformed chains fall back to the socket peer. This repository's nginx stream-proxy template is an egress proxy, not that inbound edge.

Docker browser test scripts require a local Unix-socket daemon because bind mounts and host networking must share the checkout host. They inspect the effective endpoint (`DOCKER_CONTEXT` takes precedence over `DOCKER_HOST`) and reject remote/TCP endpoints before side effects. Select an existing local context explicitly or use native Playwright; the scripts never start a daemon.

Stripe event processing requires the additive `create_stripe_webhook_events` migration before running this release. It stores only event ID/type/processing time, in the same transaction as the state changes. A duplicate returns success without repeating changes. Distinct delayed events refresh the current Stripe subscription under a per-subscription lock; user writes are serialized and manual grants are independent. Active/trial subscriptions require a bounded billing period (top-level or item period fields). A Stripe fetch failure leaves no receipt or partial entitlement; the caller retries. Fetches use a five-second receive timeout without automatic retries, within the webhook controller's existing eight-second deadline.

Reconciliation retries the bounded whole batch through the existing three-attempt Oban job when any customer fails. Successful subscriptions can be refreshed again; this is intentionally idempotent. Logs contain counts, not customer payloads. Separate per-customer jobs can be considered if customer volume makes full-batch retries costly. There is no production data backfill or manual-plan rewrite in this migration. For rollback, restore the old application only with awareness that its event-ordering/payment bugs return; the additive receipt table can remain.
