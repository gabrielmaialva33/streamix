# Changelog

All notable changes to Streamix are documented here.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Provider-aware public catalog discovery through `GET /api/v1/catalog/providers`, including safe capabilities and
  synchronized counts without upstream URLs or credentials.
- `provider_id` and `provider_type` filters across public listings, categories, featured, home, curated shelves,
  ranked search, and suggestions.
- An executable OpenAPI 3 contract for all 19 catalog operations, served as JSON at `/api/v1/openapi.json` with an
  interactive UI at `/api/v1/docs`.
- Response-contract tests covering success, validation, not-found, and authentication responses against the published
  schemas.

### Changed

- **Breaking:** catalog success responses now use a consistent `data` envelope and put pagination, applied filters,
  totals, and section metadata under `meta`. Error responses retain the stable `error.code` / `error.message` shape.
- Catalog path and query parameters are now cast and validated from the executable schema before controller code runs;
  malformed values return `400`, while missing well-formed resource identifiers return `404`.
- Public movie and series listings now aggregate active global/public providers, collapse canonical duplicates, and
  include a safe `provider` reference on every serialized catalog resource.
- Ranked movie and series search now applies the same canonicalization after relevance scoring.

## [v0.0.1] - 2026-04-13

Initial pre-release. Everything built so far is bundled into a single baseline tag.

### Added

- Phoenix 1.8 + LiveView 1.1 application scaffold with password-based auth and role-based access.
- IPTV context: Xtream Codes providers, catalog sync, channel/movie/series browsing, favorites, history, and watch
  progress.
- GIndex provider support with movies, series, anime, scraper, parser, URL cache, and workers.
- EPG database schema, sync, caching, and LiveView channel-card integration.
- AI embedding support via Gemini / NVIDIA plus Qdrant-backed semantic search and recommendations.
- RabbitMQ + Broadway as an optional distributed queue path alongside Oban.
- Billing plans, subscriptions, premium access checks, and a public plans page.
- Admin dashboard with plan CRUD, user management, and subscription management.
- Watch Party with rooms, participants, chat, presence, drift correction, and dedicated LiveViews.
- AI-powered home sections, personalized recommendations, genre filters, and viewing insights.
- TimescaleDB hypertables and continuous aggregates for event-heavy datasets.
- Signed stream URLs for all content types plus a live multiplexer path.
- Hybrid video player with HLS support, track selection, diagnostics, and buffering controls.
- Circuit breaker protection for IPTV providers.
- Service worker, manifest, installable PWA support, offline metadata sync, and update notifications.
- Client-side dark/light mode toggle and theme persistence.
- Mobile-first REST API (`/api/v1`) for auth, favorites, history, providers, telemetry, EPG, catalog, search, and
  recommendations.
- Rate limiting, CORS handling, secure stream tokens, and CSP nonces.
- Branded login/register pages, custom error pages, and a landing page with hero trailer and carousel.
- Redis + ConCache layered caching and Finch connection pooling.
- Comprehensive Oban workers for provider sync, EPG, GIndex, embeddings, and user profile updates.
- Cloudflare-oriented image proxy support.
- `mix precommit` and `mix quality` developer workflows.

[v0.0.1]: https://github.com/gabrielmaialva33/streamix/releases/tag/v0.0.1
