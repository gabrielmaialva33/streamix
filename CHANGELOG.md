# Changelog

All notable changes to Streamix are documented here.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), but the entries below are derived
from the actual git history, release tags, and the current repository state.

> Note: git tags continue through `v1.5.0`, while `mix.exs` in the current tree still reports `1.3.0`. Treat the tag
> history as release history and `HEAD` as unreleased work on top of `v1.5.0`.

## [Unreleased] - 2026-04-12

### Added

- Mobile-first REST API endpoints for auth, favorites, history, providers, telemetry, EPG, catalog, search, and
  recommendations.
- Branded two-column login/register pages, custom 404/500 error pages, and a refreshed landing page with hero trailer
  and carousel controls.
- Automatic `TEST_DATABASE_URL` inference from `DATABASE_URL`.
- Elixir 1.18 + Dialyzer wiring in the main quality workflow.
- Dead-channel marking for upstream 404 responses.

### Changed

- Rewrote the database baseline around normalized catalog/library references and stricter foreign keys.
- Moved database and Redis configuration fully into runtime environment loading.
- Expanded agent guidance and repo documentation around the real project structure and conventions.

### Fixed

- Prevented stream-loader crashes caused by idempotent `loadHls` paths.
- Disabled immutable static-asset caching in development.
- Preserved YouTube trailer domains in CSP for the landing-page hero.

## [v1.5.0] - 2026-03-29

### Added

- Billing plans, subscriptions, premium access checks, and a public plans page.
- Admin dashboard, plan CRUD, user management, and subscription management surfaces.
- Watch Party v2 with rooms, participants, chat, presence, drift correction, and dedicated LiveViews.
- AI-powered home sections, personalized recommendations, genre filters, and viewing insights.
- TimescaleDB hypertables and continuous aggregates for event-heavy datasets.
- Signed stream URLs for all content types plus a live multiplexer path.

### Changed

- Simplified and hardened stream resolution around manual redirect following and trusted proxy boundaries.
- Reworked cache, asset loading, and player buffering behavior for better startup and lower rebuffering.
- Tightened provider ownership, premium authorization, and subscription semantics.

### Fixed

- Removed provider credentials from browser-visible URLs.
- Corrected stream proxy behavior for HEAD / GET fallback paths and redirect chains.
- Improved mobile responsiveness, image fallback behavior, and watch-party UX.
- Addressed a large audit batch across frontend, backend, tests, and infra.

## [v1.4.0] - 2026-01-21

### Added

- Circuit breaker protection for IPTV providers.
- Semantic "similar content" recommendations powered by embeddings + Qdrant.
- Service worker registration, manifest, installable PWA support, and update notifications.
- Offline metadata caching for favorites and watch history.
- Client-side dark/light mode toggle and theme persistence.
- Cloudflare-oriented image proxy support.

### Changed

- Migrated infinite scroll to a sentinel / IntersectionObserver model.
- Added telemetry across sync flows.
- Improved security headers, CORS behavior, and CSP nonces.

### Fixed

- Prevented SQL pattern injection in search paths.
- Improved light-theme contrast and auth message localization.
- Reduced stream-token lifetime and removed insecure seed defaults.

## [v1.3.0] - 2026-01-03

### Added

- Hybrid video player with AVPlayer assets, HLS support, track selection, diagnostics, and buffering controls.
- GIndex provider support with movies, series, anime, scraper, parser, URL cache, and workers.
- AI embedding support via Gemini / NVIDIA plus Qdrant-backed semantic search endpoints.
- RabbitMQ + Broadway as an optional distributed queue path.
- API key-protected `/api/v1` routes and richer stream-token handling.
- EPG worker coverage and adult-content filtering.

### Changed

- Split large IPTV modules into smaller channel/movie/series/provider/history/favorite modules.
- Added Redis + ConCache layered caching and Finch pooling for sync traffic.
- Improved GIndex retry behavior and endpoint pacing.

### Fixed

- Multiple player stability issues around fallback engines, query parameters, and proxy paths.
- GIndex parser nil handling and provider credential nullability for GIndex records.
- Search behavior for non-existent or mismatched fields.

## [v1.2.0] - 2025-12-28

### Added

- EPG database schema, sync, caching, and LiveView channel-card integration.
- Unit tests covering the EPG parser and sync flow.

## [v1.1.0] - 2025-12-28

### Added

- Rate limiting, CORS handling, and secure stream tokens.
- Infinite scroll for list-heavy screens.
- Cache-backed query optimization and extra DB indexes.

### Changed

- Refactored the IPTV context into provider, catalog, channel, movie, series, favorite, and history modules.
- Updated README and repo metadata as the project matured beyond the initial scaffold.

## [v1.0.0] - 2025-12-28

### Added

- Initial Phoenix application, accounts system, IPTV context, database schema, seeds, Redis cache, and Oban jobs.
- Base web layer, provider validation, and developer tooling scaffold.

[Unreleased]: https://github.com/gabrielmaialva33/streamix/compare/v1.5.0...HEAD
[v1.5.0]: https://github.com/gabrielmaialva33/streamix/compare/v1.4.0...v1.5.0
[v1.4.0]: https://github.com/gabrielmaialva33/streamix/compare/v1.3.0...v1.4.0
[v1.3.0]: https://github.com/gabrielmaialva33/streamix/compare/v1.2.0...v1.3.0
[v1.2.0]: https://github.com/gabrielmaialva33/streamix/compare/v1.1.0...v1.2.0
[v1.1.0]: https://github.com/gabrielmaialva33/streamix/compare/v1.0.0...v1.1.0
[v1.0.0]: https://github.com/gabrielmaialva33/streamix/releases/tag/v1.0.0
