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

Historical release tags go through `v1.5.0`, but the current `mix.exs` reports `0.0.100`. Do not assume the
numeric app version is the canonical source of feature availability. Prefer the current tree and git history.

This repository is the Phoenix backend + web UI. The older in-repo TV app was extracted to a separate repository, so
do not document or modify an in-tree Tizen app here.

## Stack

- Elixir `~> 1.20`
- OTP 29
- Phoenix `~> 1.8.2`
- Phoenix LiveView `~> 1.2.0`
- Ecto SQL `~> 3.14`
- TimescaleDB on PostgreSQL 17 with `pg_trgm`
- Redis 7
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

## Project Structure

```text
lib/streamix/
├── access/                   # Permissions, role_permissions, user_permissions
├── accounts/                 # Users, roles, auth tokens, IP tracking
├── ai/                       # Embeddings, Gemini, NVIDIA, Qdrant, recommendations
├── billing/                  # Plans, subscriptions, premium access rules
├── iptv/                     # Providers, catalog, sync, stream proxy, EPG, GIndex
├── library/                  # Shared content references for progress/favorites/history
├── queue/                    # RabbitMQ/Broadway integration (optional)
├── watch_party/              # Rooms, participants, messages, room server
├── workers/                  # Oban workers
├── application.ex            # Supervision tree
├── cache.ex                  # L1 ConCache + L2 Redis
├── crypto.ex                 # AES helpers
├── helpers.ex                # Shared helpers
└── rate_limit.ex             # Hammer-backed limiter

lib/streamix_web/
├── components/               # Layouts and function components
├── controllers/              # HTML, health, stream proxy, API v1
├── helpers/                  # Image proxy helpers
├── live/                     # Home, catalog, admin, auth, watch party, providers
├── plugs/                    # API key auth, CORS, CSP nonce, rate limiting
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
└── package.json              # npm dependencies for frontend runtime
```

## Core Contexts

| Context     | Module                | Responsibility                                                  |
|-------------|-----------------------|-----------------------------------------------------------------|
| Accounts    | `Streamix.Accounts`   | Users, password auth, roles, session tokens, settings           |
| Access      | `Streamix.Access`     | Permissions and role/user grants                                |
| IPTV        | `Streamix.Iptv`       | Providers, sync, catalog access, EPG, favorites, history        |
| AI          | `Streamix.AI.*`       | Embeddings, semantic search, user analytics, Qdrant integration |
| Billing     | `Streamix.Billing`    | Plans, subscriptions, premium access                            |
| Watch Party | `Streamix.WatchParty` | Rooms, playback sync, chat, presence                            |
| Queue       | `Streamix.Queue`      | Optional RabbitMQ + Broadway execution path                     |

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
| `SyncSeriesDetailsWorker`   | on demand                      | `series_details` |
| `IndexEmbeddingsWorker`     | daily at 05:00                 | `ai`             |
| `UpdateUserProfileWorker`   | triggered from analytics flows | `ai` / async     |

## Repo-Specific Conventions

### Elixir

- Use `Req` for HTTP calls. Do not introduce HTTPoison, Tesla, or `:httpc`.
- Predicate functions end with `?`; do not invent `is_*` functions except guards.
- Never use `String.to_atom/1` on user input.
- Keep one module per file.
- Bind the result of `if` / `case` / `cond`; rebinding inside the block does not escape.
- Context entrypoints should take `user_id` or `scope` first when authorization matters.

### Phoenix / LiveView

- Current user lives at `@current_scope.user`, never `@current_user`.
- Use `<Layouts.app flash={@flash} current_scope={@current_scope}>` for standard LiveViews.
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
- The web app currently supports dark mode by default and a client-side light mode toggle.
- PWA assets live in `priv/static/manifest.json` and `priv/static/sw.js`.

## Testing

- ExUnit, Phoenix LiveViewTest, and LazyHTML are the default testing stack.
- Mirror `lib/` under `test/`.
- Prefer `start_supervised!/1` for processes started in tests.
- Do not use `Process.sleep/1` when a monitored process or message assertion is possible.
- Test rendered structure by DOM ids / stable selectors rather than fragile raw HTML text when possible.
- Run `mix precommit` before considering work complete.

## Boundaries - Never

- Auth is password-based with bcrypt. Do not document or implement magic links.
- Provider credentials are stored via `Streamix.Iptv.EncryptedField`; never log or persist plaintext passwords.
- All Xtream calls go through `Streamix.Iptv.XtreamClient`; all GIndex HTTP calls go through
  `Streamix.Gindex.Client`.
- **Context boundaries**: `Streamix.Iptv`, `Streamix.Gindex`, `Streamix.Torrent`, `Streamix.AI`,
  `Streamix.Billing`, `Streamix.WatchParty`, `Streamix.Accounts`, `Streamix.Access` are the
  public entry points. **Never** `alias` a schema or sub-module of another context from web /
  LiveView / controller code (e.g. `alias Streamix.Iptv.Movie` is wrong — call
  `Streamix.Iptv.get_movie!/1` instead). Same rule applies between contexts: `Access` does
  not `alias Streamix.Iptv.Provider` — it goes through `Streamix.Iptv.get_provider/1`.
  Internals under `Streamix.Iptv.Streaming.*`, `Streamix.Iptv.Sync.*`, `Streamix.Gindex.*`,
  `Streamix.Torrent.*` may be reorganised at will; only the facade is stable.
- Do not consume single-use IPTV tokens while resolving redirect chains. Use the existing manual redirect approach.
- RabbitMQ is optional. Respect `RABBITMQ_ENABLED`; the default path is Oban.
- GIndex is rate-limited hard. Keep sequential behavior where the code expects it.
- The TV app was extracted from this repository. Do not add docs or code assuming an in-repo Tizen frontend.
- Do not bypass `StreamixWeb.StreamToken` or leak final upstream URLs to browsers.
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
