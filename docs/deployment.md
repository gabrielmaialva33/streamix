# Production deployment contract

Production deploys one immutable image digest. The rollout is successful only
after Docker liveness, public readiness, release-revision matching, the landing
page, Service Worker and PWA manifest canaries pass. When
`DEPLOY_CANARY_EMAIL` and `DEPLOY_CANARY_PASSWORD` are configured, the same gate
also proves API login, `/me` and logout.

Database migrations run before the new container. They must therefore follow
expand/contract:

1. expand the schema while both old and new releases remain compatible;
2. deploy code that stops depending on the old shape;
3. remove or rename old data in a later release.

CI blocks new migrations containing destructive operations. A reviewed
contract step must include `# migration-safety: reviewed` next to a concise
rationale; the annotation records review, it does not make an unsafe
same-release change compatible with rollback.
