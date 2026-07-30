# Production deployment contract

Production deploys one immutable image digest using the versioned, secret-free
contract in `deploy/docker-compose.production.yml`. Secrets remain only in
`/opt/streamix/.env`, which must be mode `0600`.

Before touching the running release, the deploy:

- verifies the signed SLSA provenance and SPDX SBOM attached to the digest;
- checks the expected full Git revision;
- renders and validates the versioned Compose file;
- validates the required environment keys and external `shared_network`;
- compares the first versioned contract with the legacy live topology;
- rejects later manual drift using the last deployed Compose checksum.

The first successful rollout adopts the versioned file as
`/opt/streamix/docker-compose.production.yml`. Later changes must go through the
repository; editing that file directly makes the next deploy fail closed.
Operators can pass `DEPLOY_PREFLIGHT_ONLY=true` to
`scripts/deploy-production.sh` to validate the live contract without pulling an
image, installing the candidate Compose file, running migrations, or recreating
containers.

The rollout is successful only after Docker liveness, public readiness,
release-revision matching, the landing page, Service Worker and PWA manifest
canaries pass. When
`DEPLOY_CANARY_EMAIL` and `DEPLOY_CANARY_PASSWORD` are configured, the same gate
also proves API login, `/me` and logout.

Builds are scanned by immutable digest before `latest` is promoted. The CI
attaches signed provenance and a signed SPDX SBOM to GHCR, and both predicates
are verified again for manual digest deployments.

Database migrations run before the new container. A failed migration or canary
restores both the previous image and previous Compose contract. Migrations must
therefore follow expand/contract:

1. expand the schema while both old and new releases remain compatible;
2. deploy code that stops depending on the old shape;
3. remove or rename old data in a later release.

CI blocks new migrations containing destructive operations. A reviewed
contract step must include `# migration-safety: reviewed` next to a concise
rationale; the annotation records review, it does not make an unsafe
same-release change compatible with rollback.
