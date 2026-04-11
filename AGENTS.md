# AGENTS.md

Central instructions for any coding agent (Claude Code, Codex, Cursor, Copilot, Gemini, Amp, Jules) working on
**Streamix**. `CLAUDE.md` and `GEMINI.md` are symlinks to this file — edit here only.

> Principle: this file contains the rules that differ from framework defaults. When a rule isn't listed, follow
> stock Elixir / Phoenix 1.8 / LiveView 1.1 conventions. Detailed Phoenix/LiveView/Ecto patterns live in
> [`docs/phoenix-guidelines.md`](docs/phoenix-guidelines.md).

## Project Overview

Streamix is a unified IPTV streaming platform (v1.3.x). It aggregates multiple Xtream Codes providers into one
cinematic interface with Live TV, Movies, Series, GIndex (Google Drive), AI semantic search, watch parties, and a
REST API for mobile clients.

**Stack:** Elixir 1.18 / OTP 27 · Phoenix 1.8.2 · LiveView 1.1 · Ecto SQL 3.13 · TimescaleDB (PostgreSQL 17) ·
Redis 7 · Qdrant · RabbitMQ 4 (optional) · Oban 2.18 · Broadway · Bandit · Req · Tailwind CSS v4.

**Design:** dark mode default, light mode uses Catppuccin Latte. Netflix-inspired cinematic UI.

## Dev Environment

```bash
# Prerequisites: Elixir 1.18+ (OTP 27+), Docker

docker compose up -d        # TimescaleDB, Redis, RabbitMQ, Qdrant
cp .env.example .env        # configure secrets (never commit)
mix setup                   # deps + ecto.setup + assets.setup + assets.build
mix phx.server              # dev server
iex -S mix phx.server       # dev server with IEx shell
```

## Commands

| Command                                     | Purpose                                                                           | When                     |
|---------------------------------------------|-----------------------------------------------------------------------------------|--------------------------|
| `mix precommit`                             | compile (warnings=errors) + deps.unlock --unused + format + credo --strict + test | **Always before commit** |
| `mix test`                                  | full suite                                                                        | Before committing        |
| `mix test path/to/test.exs`                 | single file                                                                       | During development       |
| `mix test path/to/test.exs:42`              | single test by line                                                               | Debugging                |
| `mix test --failed`                         | rerun failed                                                                      | After fixing failures    |
| `mix quality`                               | compile + credo + test + dialyzer                                                 | Deep quality pass        |
| `mix format`                                | format all Elixir files                                                           | After code changes       |
| `mix credo --strict`                        | static analysis                                                                   | Code quality             |
| `mix ecto.gen.migration name_in_snake_case` | generate migration                                                                | Adding DB changes        |
| `mix ecto.migrate`                          | run pending migrations                                                            | After adding migrations  |
| `mix ecto.reset`                            | drop + create + migrate + seed                                                    | Full DB reset            |
| `mix assets.build`                          | compile CSS + JS                                                                  | Dev asset changes        |
| `mix assets.deploy`                         | minify + digest for prod                                                          | Prod builds              |
| `mix sobelow`                               | security scan (Phoenix)                                                           | Pre-release              |
| `mix deps.audit`                            | dep vulnerability scan                                                            | Pre-release              |

## Project Structure

```
lib/streamix/                   # Core business logic
├── accounts/                   # Auth (bcrypt), users, roles, scopes
├── access/                     # Permissions, role_permissions, user_permissions
├── iptv/                       # IPTV domain
│   ├── gindex/                 # Google Drive integration (scraper, endpoint_manager, url_cache, health_tracker)
│   ├── sync/                   # Provider sync (categories, movies, series, cleanup, telemetry)
│   ├── encrypted_field.ex      # AES-256-GCM for provider credentials
│   ├── xtream_client.ex        # Req-based Xtream Codes client
│   ├── xtream_circuit_breaker.ex  # Per-provider ETS circuit breaker
│   └── stream_proxy.ex         # HLS/TS proxy (hides credentials, fixes mixed content)
├── ai/                         # Gemini/NVIDIA embeddings, Qdrant, semantic search, user analytics
├── billing/                    # Subscription plans
├── cache.ex                    # L1 (ConCache, 30min) + L2 (Redis)
├── queue/                      # Broadway + RabbitMQ (optional)
├── watch_party/                # Real-time sync (room_server, messages)
├── workers/                    # Oban background jobs
├── rate_limit.ex               # Hammer rate limiter
└── crypto.ex                   # AES-GCM helpers

lib/streamix_web/
├── controllers/
│   ├── api/v1/                 # REST API (auth, catalog, search, favorites, history, EPG, recommendations)
│   ├── stream_controller.ex    # Stream proxy (HLS/TS)
│   └── health_controller.ex    # GET /api/health
├── plugs/                      # api_key_auth, cors, preserve_method, csp_nonce, rate_limit
├── live/
│   ├── admin/                  # Dashboard, plans, users
│   ├── content/                # Movie / series / episode detail
│   ├── gindex/                 # GIndex browsing
│   ├── providers/              # Provider CRUD
│   ├── watch_party_live/       # Watch party UI (index, new, show, join)
│   ├── user/                   # login_live, settings_live
│   ├── home_live.ex            # Dashboard / landing
│   ├── player_live.ex          # Fullscreen video player
│   └── search_live.ex          # Unified search (semantic + text)
└── components/                 # core_components, layouts, app_components, epg_components, player_components,
                                # watch_party_components
```

For larger contexts (plans, specs, admin panel design), see `docs/superpowers/`.

## Core Contexts

| Context    | Module                | Responsibility                                                     |
|------------|-----------------------|--------------------------------------------------------------------|
| Accounts   | `Streamix.Accounts`   | Auth, users, roles (`admin`/`customer`/`moderator`), scopes        |
| Access     | `Streamix.Access`     | Fine-grained permissions (role + user level)                       |
| IPTV       | `Streamix.Iptv`       | Providers, channels, movies, series, favorites, history, EPG, sync |
| Billing    | `Streamix.Billing`    | Plans, subscriptions                                               |
| Cache      | `Streamix.Cache`      | L1+L2 with `fetch/3` stampede prevention                           |
| AI         | `Streamix.Ai`         | Gemini/NVIDIA embeddings, Qdrant vector search                     |
| WatchParty | `Streamix.WatchParty` | Real-time sync, invite codes                                       |
| Queue      | `Streamix.Queue`      | Broadway/RabbitMQ pipelines (optional)                             |

## Background Jobs (Oban)

| Worker                      | Schedule   | Queue            |
|-----------------------------|------------|------------------|
| `SyncAllProvidersWorker`    | every 6h   | `sync`           |
| `SyncGlobalProviderWorker`  | every 4h   | `sync`           |
| `SyncGindexProviderWorker`  | daily 3 AM | `sync`           |
| `SyncEpgWorker`             | on demand  | `sync`           |
| `SyncSeriesDetailsWorker`   | on demand  | `series_details` |
| `IndexEmbeddingsWorker`     | daily 5 AM | `ai`             |
| `CleanupOrphanedDataWorker` | daily 2 AM | `default`        |

## Key Subsystems

- **Stream Proxy** (`StreamController` + `Iptv.StreamProxy`): resolves IPTV redirect chains and proxies HLS/TS
  through Elixir to fix mixed content (HTTP→HTTPS) and hide credentials. Uses `Req` with `redirect: :manual` so
  single-use provider tokens aren't consumed during URL resolution.
- **Circuit Breaker** (`Iptv.XtreamCircuitBreaker`): per-provider ETS state. Thresholds: 5 errors / 60s → OPEN,
  3-minute recovery → HALF_OPEN. Prevents cascade failures.
- **Cache** (`Streamix.Cache`): L1 ConCache (ETS, 30 min TTL, per-node) → L2 Redis (distributed, configurable TTL).
  Write-through. Pattern-based invalidation via Redis SCAN.
- **GIndex** (`Iptv.Gindex`): multi-endpoint failover with `EndpointManager` + `HealthTracker`, URL caching with
  TTL, async scraping. **Concurrency: 1** — GIndex has aggressive rate limits, do NOT parallelize.
- **Rate Limits** (Hammer): auth 5 req/min, stream proxy 60 req/min, API v1 120 req/min.
- **CSP**: dynamic nonces via `Plugs.CSPNonce`. No inline scripts allowed.

## Code Style

### Elixir

- HTTP client: **always `Req`**. Never HTTPoison, Tesla, Mint directly, or `:httpc`.
- Predicate functions end with `?`, never start with `is_` (reserve `is_` for guards).
- Don't use `String.to_atom/1` on user input (memory leak risk).
- Never nest multiple modules in one file.
- Block expressions (`if`, `case`, `cond`) must **bind their result** — rebinding inside a block doesn't escape.
- First argument of context functions is `user_id` or `scope` for authorization.
- Use `Task.async_stream/3` for concurrent work with back-pressure (usually `timeout: :infinity`).

### Phoenix / LiveView

- Access current user via `@current_scope.user` — **never** `@current_user`. Routes in different `live_session`
  blocks trigger full reloads on navigate; keep related routes in the same session.
- Wrap all LiveView templates in `<Layouts.app flash={@flash} current_scope={@current_scope}>`.
- Icons: `<.icon name="hero-*">`. Never import Heroicons modules directly.
- Forms: `to_form/2` → `@form[:field]`. Never pass changesets to templates.
- Collections: **always** use LiveView streams — never assign raw lists, never `phx-update="append"/"prepend"`.
- Navigation: `<.link navigate={}>` / `<.link patch={}>`. Never `live_redirect` / `live_patch`.
- No inline `<script>` tags — use colocated hooks (`:type={Phoenix.LiveView.ColocatedHook}`, name starts with `.`).
- LiveComponents: avoid unless strongly justified.

### HEEx

- Always `~H` or `.html.heex`. Never `~E`, never `Phoenix.HTML.form_for`, never `Phoenix.View`.
- Attribute interpolation: `{@value}`. Tag body: `{@value}` or `<%= ... %>` for blocks. Never `<%= @v %>` inside
  an attribute.
- Class lists use `[...]` syntax. Comments: `<%!-- ... --%>`.
- Never `<% Enum.each %>` — always `<%= for item <- @collection do %>`.

### Ecto / Database

- Schema fields use `:string` for both `varchar` and `text`.
- Always preload associations accessed in templates.
- Fields set programmatically (`user_id`, timestamps, etc.) **must not** be in `cast/3` — set explicitly.
- Read changeset fields with `Ecto.Changeset.get_field/2`, not map access.
- `validate_number/2` has no `:allow_nil` — validations skip nil by default.
- Always generate migrations via `mix ecto.gen.migration name_in_snake_case`.
- TimescaleDB (PG17) with `pg_trgm` extension for fuzzy search.

### CSS / Frontend

- Tailwind CSS v4 with `@import "tailwindcss"` in `app.css`. No `@apply`, no daisyUI, no `tailwind.config.js`.
- Import vendor deps into `app.js` / `app.css`. No external `src`/`href` in layouts.
- Dark mode is default; light mode uses the Catppuccin Latte palette.

## Testing

- ExUnit + `Phoenix.LiveViewTest` + `LazyHTML`.
- Test files mirror `lib/` layout under `test/`.
- Use `start_supervised!/1` for processes in tests — ensures cleanup.
- Never `Process.sleep/1`. Use `Process.monitor/1` + `assert_receive {:DOWN, ...}` or `:sys.get_state/1`.
- Test element presence by DOM IDs, **not** raw HTML text.
- Use `render_submit/2` / `render_change/2` for form tests.
- Always run `mix precommit` before committing.

## Git / PR

- Run `mix precommit` and fix all issues before opening a PR.
- Commit messages: concise, focus on the **why**, not the what.
- Keep PRs focused on a single concern.
- Never commit `.env`, secrets, API keys, or plaintext IPTV credentials.
- `warnings-as-errors` is enforced by `mix precommit` — no compiler warnings allowed.

## Boundaries — NEVER

These are the top mistakes agents make in this codebase. Read before writing any code.

- **Auth is password-based (bcrypt)**, NOT magic link / passwordless. Don't reference magic links anywhere.
- **Provider credentials are AES-256-GCM encrypted** via `Iptv.EncryptedField`. Never store plaintext passwords.
- **Don't consume IPTV tokens during URL resolve.** Some providers use single-use tokens — the resolve step must
  NOT consume them. Use GET with `redirect: :manual`.
- **Never log raw provider responses** — they may contain credentials or tokens. Mark sensitive schema fields
  `redact: true`.
- **All external IPTV calls go through `Iptv.XtreamClient`** (or `Iptv.Gindex.Client`). No ad-hoc `Req.get/1`.
- **RabbitMQ is optional** and disabled by default — check `RABBITMQ_ENABLED`. When disabled, everything falls
  back to Oban. Don't assume Broadway pipelines are running.
- **GIndex concurrency = 1.** Do not parallelize requests — you will get throttled and break the endpoint pool.
- **LiveView cross-session navigation causes full reloads.** Keep related routes in the same `live_session` block.
- **Never** use: `live_redirect`, `live_patch`, `Phoenix.View`, `Phoenix.HTML.form_for`, `Phoenix.HTML.inputs_for`,
  `phx-update="append"`, `phx-update="prepend"`, `@current_user`, `String.to_atom/1` on user input, `@apply` in
  CSS, nested modules in one file, inline `<script>` tags, raw list assigns for collections, changeset access in
  templates.

## Infrastructure

- **DB:** TimescaleDB (PostgreSQL 17) + pg_trgm.
- **Cache L1:** ConCache (ETS, 30 min TTL, per-node).
- **Cache L2:** Redis 7 (distributed).
- **Vector DB:** Qdrant (semantic search).
- **Message queue:** RabbitMQ 4 (optional).
- **HTTP server:** Bandit. **HTTP client:** Req + Finch (pool 50 × 4).

## Deploy

- **Image:** `ghcr.io/gabrielmaialva33/streamix:latest`.
- **Dockerfile:** multi-stage (Elixir 1.18.2, OTP 27.2.1, Debian bookworm).
- **Health:** `GET /api/health`.
- **Infra:** TimescaleDB, Redis, Cloudflare Tunnel.
- **Secret management:** `.env` via `dotenvy`. Never commit secrets.

## Reference

- [`docs/phoenix-guidelines.md`](docs/phoenix-guidelines.md) — detailed Phoenix / LiveView / Ecto patterns
  (HEEx interpolation, stream operations, form handling, JS hooks, test patterns).
- `docs/superpowers/plans/` — active implementation plans.
- `docs/superpowers/specs/` — design specs.
- `docs/nginx-stream-proxy.conf` — reference nginx config for the stream proxy.
