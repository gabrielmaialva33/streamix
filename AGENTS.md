# AGENTS.md

Central instructions for coding agents working on **Streamix**. `CLAUDE.md` and `GEMINI.md` import this file with
`@AGENTS.md`, so update this document only.

> Principle: this file only captures repo-specific rules. When a rule is not listed here, follow standard
> Elixir / Phoenix 1.8 / LiveView 1.2 conventions and the detailed guidance in
> [`docs/phoenix-guidelines.md`](docs/phoenix-guidelines.md).

## Project Overview

Streamix is a Phoenix + LiveView streaming platform that aggregates multiple Xtream Codes providers into a single web
application and REST API. The current tree includes:

- password-based authentication and role-based access
- personal providers plus optional system-wide global provider
- optional GIndex ingestion for Google Drive-backed catalogs
- live channels, movies, series, episodes, favorites, history, and watch progress
- AI-assisted semantic search and recommendations when embeddings + Qdrant are configured
- watch parties with synchronized playback, presence, and room chat
- subscription plans, premium access gates, and an admin panel
- signed stream URLs, a Phoenix stream proxy, and a live stream multiplexer
- PWA assets, offline metadata sync hooks, and a mobile / TV-facing REST API

The application release version is sourced from the root `VERSION` file (currently `0.0.100`) and consumed by
`mix.exs`. Historical release tags go through `v1.5.0`; do not infer feature availability by comparing those two
version lines. Prefer the current tree and git history.

This repository is the Phoenix backend + web UI. The older in-repo TV app was extracted to a separate repository, so
do not document or modify an in-tree Tizen app here.

## Stack

- Elixir `~> 1.20`
- OTP 29
- Phoenix `~> 1.8.2`
- Phoenix LiveView `~> 1.2.0`
- Ecto SQL `~> 3.14`
- TimescaleDB on PostgreSQL 17 with `pg_trgm`
- Redis 8
- Qdrant (optional, for semantic search)
- RabbitMQ 4 + Broadway (optional)
- Oban 2.23
- Req + Finch
- Tailwind CSS v4
- esbuild
- npm 12-managed frontend packages in `assets/`

## Local Setup

```bash
docker compose up -d
cp .env.example .env
cd assets && npm ci && cd ..
mix setup
mix phx.server
```

Important local setup facts:

- `mix setup` runs `ecto.setup`, seeds, and asset builds.
- `priv/repo/seeds.exs` requires `ADMIN_PASSWORD`.
- provider credential encryption requires `PROVIDER_ENCRYPTION_KEY`.
- `assets/node_modules` is ignored, so local JS dependencies require `npm ci`.
- if `TEST_DATABASE_URL` is not set, test config derives it from `DATABASE_URL`.

## Common Commands

| Command                        | Purpose                                                      |
|--------------------------------|--------------------------------------------------------------|
| `mix setup`                    | deps, DB setup, seeds, asset setup/build                     |
| `mix phx.server`               | run the web app                                              |
| `iex -S mix phx.server`        | run with IEx                                                 |
| `mix test`                     | full test suite                                              |
| `mix test path/to/test.exs`    | targeted test file                                           |
| `mix test path/to/test.exs:42` | targeted test by line                                        |
| `mix precommit`                | compile warnings-as-errors, deps.unlock, format, credo, test |
| `mix quality`                  | compile, credo, test, dialyzer                               |
| `mix ecto.migrate`             | run migrations                                               |
| `mix ecto.reset`               | drop, create, migrate, seed                                  |
| `mix assets.build`             | build CSS + JS                                               |
| `mix assets.deploy`            | minify and digest assets                                     |
| `cd assets && npm ci`          | install frontend dependencies                                |

## Dependency Currency

- Track the latest stable releases for Hex, npm, Docker / Compose, and GitHub Actions. Dependabot checks all four
  ecosystems daily through `.github/dependabot.yml`.
- Keep GitHub Actions pinned to immutable commit SHAs and retain the release tag in a comment.
- A stateful infrastructure major (PostgreSQL, TimescaleDB, Redis, RabbitMQ, Qdrant) still requires a rehearsed data
  migration and rollback; "latest" never means replacing a production data format blindly.
- A deploy only recreates the `streamix` container (`--no-deps`, guarded by `DeployContractTest`). A new infra image
  in `deploy/docker-compose.production.yml` takes effect only when that service is recreated by hand on the VPS, at an
  agreed time: Postgres and Redis there are shared with other apps (BullMQ queues in Redis, other apps' databases in
  Postgres). Back up first (`/opt/streamix/bin/backup-database.sh`), recreate one service with
  `docker compose --env-file /opt/streamix/.env -f /opt/streamix/docker-compose.production.yml up -d --no-deps <svc>`,
  and after a TimescaleDB image run `ALTER EXTENSION timescaledb UPDATE;` (`psql -X`, first command of a session) in
  `streamix_prod`, then restart `streamix`: pooled sessions keep the old library and fail with "already loaded with a
  different version".

## Project Structure

```text
lib/streamix/
├── access/                   # Permissions, role_permissions, user_permissions
├── accounts/                 # Users, roles, auth tokens, IP tracking
├── ai/                       # Embeddings, Gemini, NVIDIA, Qdrant, recommendations
├── billing/                  # Plans, subscriptions, premium access rules
├── cache/                    # L1 ConCache and L2 Redis implementations
├── ecto/                     # Shared Ecto types
├── gindex/                   # GIndex transport, parsing, matching, quota, and sync
├── hls/                      # Shared HLS gateway: playlist rewrite, bounded fetch, registry
├── iptv/                     # Canonical catalog, providers, EPG, engagement, and streaming
├── qoe/                      # Privacy-bounded playback quality events
├── queue/                    # RabbitMQ/Broadway integration (optional)
├── security/                 # Shared URL and network-boundary validation
├── subtitles/                # Subtitle providers, normalization, and VTT conversion
├── torrent/                  # Torrent catalog, sources, sync, and stream sessions
├── watch_party/              # Rooms, participants, messages, room server
├── workers/                  # Oban workers
├── application.ex            # Supervision tree
├── runtime_*.ex              # Parsed runtime settings and test-service safety guards
└── rate_limit.ex             # Hammer-backed limiter

lib/streamix_web/
├── api/                      # OpenAPI document and reusable API schemas
├── catalog/                  # Web/API catalog serialization and stream URLs
├── components/               # Layouts and function components
├── content/                  # Shared content-loading presentation services
├── controllers/              # HTML, health, stream proxy, API v1
├── helpers/                  # Image proxy helpers
├── live/                     # Home, catalog, admin, auth, watch party, providers
├── on_mount/                 # Reusable LiveView lifecycle hooks
├── plugs/                    # API key auth, CORS, CSP nonce, rate limiting
├── stream_token/             # Signed stream-token resolution and signing internals
├── telemetry/                # Web telemetry and request measurements
├── presence.ex               # Watch party presence
├── router.ex                 # Browser + API routes
├── stream_token.ex           # Signed URLs for stream access
└── user_auth.ex              # Session/auth plumbing

assets/
├── css/app.css               # Thin Tailwind v4 entrypoint; ordered domain imports
├── css/*.css                 # Platform, theme, catalog, player, PWA, and surface styles
├── js/app.js                 # Thin browser composition root
├── js/bootstrap/             # LiveView and document-level browser setup
├── js/core/                  # Shared browser primitives
├── js/hooks/                 # LiveView hooks
├── js/media/                 # Codec, buffering, decoder, and stream integrations
├── js/player/                # Playback state, policy, controls, and UI
├── js/pwa/                   # Install, cache, offline, and service-worker integration
├── js/telemetry/             # Privacy-bounded browser diagnostics
├── js/test/                  # Node tests for extracted browser modules
└── package.json              # npm dependencies for frontend runtime
```

## Core Contexts

Delivery code (controllers, LiveViews, workers) calls these modules and nothing beneath them.

| Context     | Module                | Responsibility                                                  |
|-------------|-----------------------|-----------------------------------------------------------------|
| Accounts    | `Streamix.Accounts`   | Users, password auth, roles, session tokens, settings           |
| Access      | `Streamix.Access`     | Permissions and role/user grants                                |
| Catalog     | `Streamix.Catalog`    | Movies, series, episodes, channels, categories, shelves, assets |
| Search      | `Streamix.Search`     | Search, autocomplete, semantic discovery, TMDB lookup           |
| Library     | `Streamix.Library`    | Favorites, watch history, playback progress                     |
| Playback    | `Streamix.Playback`   | Playability, source selection, failover, stream URLs, proxying  |
| Providers   | `Streamix.Providers`  | Provider lifecycle, visibility, health, sync                    |
| Guide       | `Streamix.Guide`      | EPG sync and TV-guide queries                                   |
| GIndex      | `Streamix.Gindex`     | Drive discovery, quota-aware ingestion, and URL resolution      |
| Torrent     | `Streamix.Torrent`    | Torrent sources, catalog synchronization, and stream lifecycle  |
| AI          | `Streamix.AI`         | Embeddings, semantic search, user analytics, Qdrant integration |
| Billing     | `Streamix.Billing`    | Plans, subscriptions, premium access                            |
| QoE         | `Streamix.Qoe`        | Playback quality telemetry and retention                        |
| Subtitles   | `Streamix.Subtitles`  | Subtitle discovery, normalization, and conversion               |
| Watch Party | `Streamix.WatchParty` | Rooms, playback sync, chat, presence                            |
| Queue       | `Streamix.Queue`      | Optional RabbitMQ + Broadway execution path                     |

The six IPTV boundaries (Catalog through Guide) are implemented under `Streamix.Iptv.*`, which is internal. There is
no `Streamix.Iptv` module: the old compatibility facade was retired and a test keeps it retired. A public
function/arity has exactly one owning boundary — see [`docs/application-boundaries.md`](docs/application-boundaries.md).

## Routes and Surfaces

Main browser surfaces:

- `/` public landing page
- `/plans` public plans page
- `/login`, `/register`, `/settings`
- `/browse`, `/browse/movies`, `/browse/series`, `/browse/animes`
- `/providers/...` personal provider management and scoped browsing
- `/favorites`, `/history`
- `/gindex/...` GIndex catalog pages
- `/party`, `/party/:invite_code`, `/party/:invite_code/watch`
- `/watch/:type/:id`
- `/admin`, `/admin/plans`, `/admin/users`

API surfaces under `/api/v1`:

- auth: register, login, logout, me
- catalog: featured, movies, series, channels, categories, stream URLs
- search: semantic search, similar, status, info
- recommendations: personalized, similar, channels, insights, refresh
- favorites, history, EPG, telemetry, providers

## Background Jobs

| Worker                      | Schedule / Trigger             | Queue            |
|-----------------------------|--------------------------------|------------------|
| `CleanupOrphanedDataWorker` | daily at 02:00                 | `default`        |
| `SyncAllProvidersWorker`    | every 6h                       | `sync`           |
| `SyncGlobalProviderWorker`  | every 4h                       | `sync`           |
| `SyncGindexProviderWorker`  | daily at 03:00                 | `sync`           |
| `SyncEpgWorker`             | on demand                      | `sync`           |
| `SyncDueEpgWorker`          | hourly at :40                  | `sync`           |
| `SyncSeriesDetailsWorker`   | on demand                      | `series_details` |
| `TmdbDetailsWorker`         | daily at 04:45                 | `tmdb_details`   |
| `EpisodeDetailsWorker`      | daily at 05:15                 | `tmdb_details`   |
| `BackfillTmdbMetadataWorker`| daily at 05:45                 | `tmdb_details`   |
| `IndexEmbeddingsWorker`     | daily at 05:00                 | `ai`             |
| `ClassifyTitleTagsWorker`   | hourly at :25                  | `tags`           |
| `UpdateUserProfileWorker`   | triggered from analytics flows | `ai` / async     |

## Repo-Specific Conventions

### Elixir

- Use `Req` for HTTP calls. Do not introduce HTTPoison, Tesla, or `:httpc`.
- Predicate functions end with `?`; do not invent `is_*` functions except guards.
- Never use `String.to_atom/1` on user input.
- Keep one module per file.
- Bind the result of `if` / `case` / `cond`; rebinding inside the block does not escape.
- Context entrypoints should take `user_id` or `scope` first when authorization matters.
- Logging: a constant message plus metadata. Never interpolate a reason, URL or upstream response into the message;
  pass it as `reason: Streamix.SafeLog.redact_inspect(reason)` (URLs: `SafeLog.redact_url/1`). New metadata keys
  must be added to the `:default_formatter` list in `config/config.exs` or they are dropped.
- Configuration: `config/runtime.exs` parses the environment (through `Streamix.RuntimeConfig` for booleans and
  integers). Each `:streamix` key has one reading module; other code calls that module (for example
  `Streamix.PublicUrls.stream_proxy/0`) instead of repeating `Application.get_env` with its own default.
- Workers live in `lib/streamix/workers/` (grouped by source in subfolders) and `use Oban.Worker`.

### Phoenix / LiveView

- Current user lives at `@current_scope.user`, never `@current_user`.
- Layouts come from the router: each `live_session` sets `layout:`. LiveViews do not wrap themselves in
  `<Layouts.app>`.
- A `return_to` parameter is only read through `StreamixWeb.ReturnPath.safe/1` and only written with
  `StreamixWeb.ReturnPath.append/2`; never hand-roll the check.
- `lib/streamix_web/` root holds only cross-cutting web infrastructure (endpoint, router, user_auth, stream_token,
  presence, telemetry, gettext, locale, return_path). Everything else goes in `live/`, `controllers/`, `components/`,
  `plugs/`, `on_mount/`, `telemetry/`, `content/` or `catalog/`.
- Use `<.link navigate={}>` and `<.link patch={}>`, never `live_redirect` / `live_patch`.
- Collections in LiveView must use streams, not raw list assigns with append/prepend DOM updates.
- Use colocated hooks or `assets/js/hooks`; no inline `<script>` tags.
- Avoid LiveComponents unless there is a real state or reuse reason.

### HEEx

- Use `~H` or `.html.heex`, never `~E`.
- Use `{@value}` in attributes and `<%= ... %>` only for block constructs.
- Use `<%= for ... do %>`, never `<% Enum.each %>`.
- Use `<%!-- ... --%>` for template comments.

### Ecto / Database

- Use `:string` for text-like columns unless a different Ecto type is actually required.
- Do not `cast/3` programmatic fields like `user_id`.
- Read changes from changesets with `Ecto.Changeset.get_field/2`.
- Generate new migrations with `mix ecto.gen.migration ...`, unless the user explicitly asks for a baseline rewrite.
- The current schema uses TimescaleDB features for watch/EPG/watch-party event data. Be careful when changing
  hypertables, retention, compression, or continuous aggregates.

### Frontend

- Tailwind CSS v4 only. No `@apply`, no `tailwind.config.js`, no daisyUI rollout.
- Frontend packages come from `assets/package.json`; remember `npm ci`.
- The web app is dark-only. Colors come from the tokens in `assets/css/theme.css`.
- JS conventions (module roles, imports, timers, logging, tests) live in [`assets/README.md`](assets/README.md).
- PWA sources live in `priv/manifest.json` and `priv/sw.js`; controllers serve both with release-aware cache headers.

## Testing

- ExUnit, Phoenix LiveViewTest, and LazyHTML are the default testing stack.
- Mirror `lib/` under `test/`.
- Prefer `start_supervised!/1` for processes started in tests.
- Do not use `Process.sleep/1` when a monitored process or message assertion is possible.
- Test rendered structure by DOM ids / stable selectors rather than fragile raw HTML text when possible.
- Run `mix precommit` before considering work complete; `mix dialyzer` and, for frontend changes,
  `cd assets && npm run lint && npm test` are also CI gates.
- API v1 changes: every `/api/v1` route has an OpenAPI operation, errors go through
  `action_fallback StreamixWeb.Api.V1.FallbackController` and `Api.V1.Response`, and the spec must pass
  `mix openapi.spec.json --spec StreamixWeb.Api.V1.OpenApi --start-app=false --vendor-extensions=false <file>`
  followed by `npm --prefix assets run lint:openapi -- <file>` (a CI gate). In OpenAPI 3.0 `nullable` needs a sibling
  `type`.
- The test database name must end in `_test` (`TEST_DATABASE_URL`), or the runtime safety guard refuses it.
- Architecture tests in `test/streamix/architecture/` enforce boundaries, module layout and test mirroring; fix the
  code, not the test.

## Commits and Changelog

- Commit subjects follow `type(scope): summary` with `type` in `feat`, `fix`, `perf`, `refactor`, `test`, `docs`,
  `chore`, `ci`, `style`. One theme per commit; the body says why.
- A change a user, operator or API consumer can notice gets a line under `## [Unreleased]` in `CHANGELOG.md`
  (Added / Changed / Fixed / Security) in the same commit.

## Boundaries - Never

- Auth is password-based with bcrypt. Do not document or implement magic links.
- Provider credentials are stored via `Streamix.Iptv.EncryptedField`; never log or persist plaintext passwords.
- All Xtream calls go through `Streamix.Iptv.XtreamClient`; all GIndex HTTP calls go through
  `Streamix.Gindex.Client`.
- **Context boundaries**: the modules in the Core Contexts table, plus `Streamix.Gindex`, `Streamix.Torrent`,
  `Streamix.Embedplay` and `Streamix.Subtitles`, are the public entry points. **Never** `alias` a schema or
  sub-module of another context from web / LiveView / controller code (e.g. `alias Streamix.Iptv.Movie` is wrong —
  call `Streamix.Catalog.get_movie!/1` instead). Same rule applies between contexts: `Access` does not
  `alias Streamix.Iptv.Provider` — it goes through `Streamix.Providers.get_provider/1`. Internals under
  `Streamix.Iptv.*`, `Streamix.Gindex.*`, `Streamix.Torrent.*` may be reorganised at will; only the boundary is
  stable. A new public function goes on the boundary that owns it — never on a second boundary.
- Do not consume single-use IPTV tokens while resolving redirect chains. Use the existing manual redirect approach.
- RabbitMQ is optional. Respect `RABBITMQ_ENABLED`; the default path is Oban.
- GIndex is rate-limited hard. Keep sequential behavior where the code expects it.
- The TV app was extracted from this repository. Do not add docs or code assuming an in-repo Tizen frontend.
- Do not bypass `StreamixWeb.StreamToken` or leak final upstream URLs to browsers. The single,
  owner-approved exception is direct-client playback: only for providers with the operator-only
  `providers.direct_client_playback` flag, only for progressive VOD (a movie or episode whose
  delivery probe resolved to a progressive source), and only after full token authorization,
  `/api/stream/vod/direct.<container>` answers `302` to the final CDN URL resolved server-side —
  `https`, without userinfo, and never containing the account password (it may carry the account
  username and a short-lived CDN token). Never log that URL. HLS (always via the gateway), live,
  provider panel URLs and every other upstream URL stay server-side. See
  [`docs/xtream-direct-playback.md`](docs/xtream-direct-playback.md).
- Do not introduce `live_redirect`, `live_patch`, `Phoenix.View`, `Phoenix.HTML.form_for`,
  `phx-update="append"`, `phx-update="prepend"`, or `@current_user`.

## References

- [`README.md`](README.md)
- [`README.pt.md`](README.pt.md)
- [`CHANGELOG.md`](CHANGELOG.md)
- [`CONTRIBUTING.md`](CONTRIBUTING.md)
- [`SECURITY.md`](SECURITY.md)
- [`docs/phoenix-guidelines.md`](docs/phoenix-guidelines.md)
- [`docs/nginx-stream-proxy.conf`](docs/nginx-stream-proxy.conf)
