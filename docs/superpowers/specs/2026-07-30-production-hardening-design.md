# Production Hardening Design

**Status:** approved in conversation on 2026-07-30

## Outcome

Remove the verified production hazards and browser noise without expanding the
work into an image-proxy service, an anime semantic-search feature, or a torrent
subsystem rewrite.

The change is complete when:

- cache invalidation cannot delete non-cache Redis state;
- tests cannot silently reuse a remote production Redis database;
- VOD redirects with unescaped path characters resolve successfully;
- streaming errors retain diagnostic context without logging credentials or tokens;
- public catalog cards avoid requests to hosts proven unusable in browsers;
- mobile "Ver mais" links expose a touch target at least 44 pixels high;
- the player capability report does not request an unused WebGPU adapter;
- targeted tests, the JavaScript suite, `mix precommit`, and an authenticated
  production-style browser smoke pass.

## Scope

### Redis cache ownership

`Streamix.Cache.L2` will own the Redis namespace `cache:`. Public cache callers
continue using their current logical keys; prefixing and stripping stay private
to L2.

- `get`, `set`, and `delete` translate logical keys to `cache:<logical-key>`.
- pattern deletion scans only `cache:<logical-pattern>`.
- callbacks receive the original logical key so L1 invalidation remains unchanged.
- `Cache.invalidate_all/0` clears L1 and deletes `cache:*` through SCAN/DEL.
- `FLUSHDB` support is removed from the cache layer.
- unrelated keys such as `gindex:quota:*` and `stream_redirect:*` survive every
  cache invalidation.

Existing unprefixed cache entries are not migrated. They are bounded by TTL and
may expire naturally; reading them again would reintroduce ambiguity about key
ownership.

### Test Redis safety

Test runtime configuration gains an explicit Redis safety boundary:

- `TEST_REDIS_URL` is the authoritative test override.
- without that override, a local or allowlisted Compose `REDIS_URL` is rewritten
  to Redis database 15;
- a remote host fails closed by default;
- an intentional remote test Redis requires both a non-zero Redis database and
  `ALLOW_REMOTE_TEST_REDIS=i-know-this-is-a-test-redis`;
- `TEST_REDIS_ALLOWED_HOSTS` may add validated Compose service names, matching
  the database safety model;
- production continues using `REDIS_URL` unchanged.

The error message identifies only host and database number. It never prints the
full URL or credentials.

### VOD redirect normalization and safe logging

`RedirectResolver` will normalize every `Location` value before the next request.
Only invalid characters in the URI path are percent-encoded. Existing `%HH`
escapes, path separators, the query string, and query values remain semantically
unchanged.

The shared `Streamix.SafeLog` boundary gains a bounded redacted inspection helper.
Streaming log sites use it for nested exceptions and transport reasons instead
of interpolating raw `inspect/1` output. Redaction covers Xtream credential path
segments, URL userinfo, and sensitive query names such as `token`, `password`,
and `api_key`.

The resolver still returns the original reason to callers and telemetry. Logging
sanitization must not alter retry classification or fallback behavior.

### Browser presentation

`ImageProxy` gains a browser-specific poster resolver for the two verified
hotlink/ORB hosts: `png.pngtree.com` and `static.vecteezy.com`. It returns `nil`
for those hosts so the existing public-home `ImageFallback` markup renders its
local fallback without issuing a doomed network request. Other image and API
serialization paths keep their current behavior.

The shared section header makes "Ver mais" an `inline-flex` target with a minimum
height of 44 pixels on mobile while retaining the compact desktop presentation.

Hardware detection keeps WebGL/WebGL2 checks and reports WebGPU API presence,
but does not call `navigator.gpu.requestAdapter()` during player mount. No
playback decision currently consumes adapter availability.

## Explicit Non-Goals

- No manifest or service-worker change: a fresh browser context receives the
  correct share-target encoding and no warning.
- No Qdrant recovery change: all required collections are currently healthy.
- No anime indexing in this patch: the empty anime collection reflects an
  unimplemented product surface and needs its own design.
- No rqbit API change: readiness is healthy and current logs contain no reaper
  failures.
- No generic public image-fetch endpoint or expanded SSRF surface.
- No deployment, production Redis mutation, forced GIndex wake-up, or manual
  reindex as part of the code patch.

## Error Handling

- Redis scan errors keep the existing best-effort invalidation contract and are
  logged with the logical pattern, never a connection URL.
- Invalid or credential-bearing VOD reasons are bounded and redacted before
  logging.
- A malformed redirect that cannot be normalized remains an ordinary resolver
  error and follows the existing retry/fallback path.
- A blocked public poster host produces the normal local visual fallback, not a
  broken image element.

## Verification

Each production behavior is introduced through a failing regression test:

1. an operational Redis key survives `Cache.invalidate_all/0`;
2. L2 reads, writes, deletes, and patterns are confined to `cache:*`;
3. runtime test configuration rejects remote Redis reuse and derives local DB 15;
4. a redirect containing spaces reaches its percent-encoded target;
5. a nested request error cannot leak a token through log formatting;
6. blocked public poster hosts render without an external image source;
7. section-header touch geometry is at least 44 pixels in the mobile browser test;
8. capability reporting succeeds without calling `requestAdapter()`.

Targeted tests run after every RED/GREEN cycle. Final validation runs:

```bash
cd assets && npm test
mix precommit
```

The browser smoke repeats the public-home console/network audit, mobile touch
measurement, authenticated player playback, and audio state synchronization.
