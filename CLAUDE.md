# CLAUDE.md

## Common Pitfalls

These are things that Claude keeps getting wrong in this project. Read before writing any code.

- **Auth is password-based (bcrypt), NOT magic link.** Users register with email + password. Roles: `admin`, `customer`, `moderator`. Don't reference "magic link" or "passwordless" anywhere.
- **Access user via `@current_scope.user`, NEVER `@current_user`.** Phoenix 1.8 scope pattern. If you get `current_scope` errors, check the router — your route is in the wrong `live_session`.
- **Provider credentials are AES-256-GCM encrypted.** The `Iptv.EncryptedField` handles this. Never store plaintext passwords for IPTV providers.
- **Streams are proxied through Elixir, not direct redirects.** The `StreamController` resolves redirect chains and proxies HLS/TS content. This avoids mixed-content (HTTP→HTTPS) and credential leaks.
- **Don't consume IPTV tokens during URL resolve.** Some providers use single-use tokens. The resolve step (following redirects to get final URL) must NOT consume the token — use GET-only resolve with `redirect: :manual`.
- **GIndex endpoints have aggressive rate limits.** Default concurrency is 1. Don't parallelize GIndex requests or you'll get throttled.
- **RabbitMQ is optional and disabled by default.** Check `RABBITMQ_ENABLED` env var. When disabled, everything falls back to Oban. Don't assume Broadway pipelines are running.
- **LiveView cross-session navigation causes full reloads.** Routes in different `live_session` blocks trigger a warning "navigate event failed because you are redirecting across live_sessions". This is expected — keep related routes in the same session.

## Project Overview

Streamix is a unified IPTV streaming platform built with **Elixir 1.18**, **Phoenix 1.8**, **LiveView 1.1**, **TimescaleDB (pg17)**, **Redis 7**, and **Tailwind CSS v4**.

It aggregates multiple Xtream Codes IPTV providers into one cinematic interface with Live TV, Movies, Series, Google Drive content (GIndex), AI-powered search, and a full REST API for mobile clients.

**Design:** Dark mode (default) + Light mode with Catppuccin Latte palette. Netflix-inspired cinematic UI.

## Commands

```bash
# Dev server
mix phx.server                      # start server
iex -S mix phx.server               # with IEx shell

# Tests
mix test                            # all tests
mix test test/path/to/test.exs      # single file
mix test test/path_test.exs:42      # single test by line
mix test --failed                   # rerun failed

# Pre-commit (ALWAYS run before committing)
mix precommit  # compile --warnings-as-errors + format + credo --strict + test

# Database
mix ecto.gen.migration name_in_snake_case
mix ecto.migrate
mix ecto.reset                      # drop + create + migrate + seed

# Assets
mix assets.build                    # dev build
mix assets.deploy                   # prod (minify + digest)

# Full setup (first time)
mix setup                           # deps + ecto.setup + assets
```

## Architecture

### Directory Layout

```
lib/streamix/                       # Core business logic
├── accounts/                       # User auth, roles, scopes
├── iptv/                           # IPTV domain (providers, channels, movies, series)
│   ├── gindex/                     # Google Drive integration
│   └── sync/                       # Provider sync logic
├── ai/                             # Embeddings, semantic search
├── billing/                        # Subscription plans
├── cache.ex                        # L1 (ConCache) + L2 (Redis) hybrid cache
├── queue/                          # Broadway + RabbitMQ (optional)
├── watch_party/                    # Real-time watch sync
├── workers/                        # Oban background jobs
└── rate_limit.ex                   # Hammer rate limiting

lib/streamix_web/                   # Web layer
├── controllers/
│   ├── api/v1/                     # REST API (auth, catalog, search, favorites, history, EPG)
│   ├── stream_controller.ex        # Stream proxy (HLS/TS)
│   └── health_controller.ex        # /api/health
├── live/
│   ├── admin/                      # Admin panel (dashboard, plans, users)
│   ├── content/                    # Movie/series detail pages
│   ├── gindex/                     # GIndex browsing
│   ├── providers/                  # Provider management
│   ├── watch_party_live/           # Watch party UI
│   ├── home_live.ex                # Dashboard / landing
│   ├── player_live.ex              # Video player (fullscreen)
│   └── search_live.ex              # Unified search
└── components/
    ├── core_components.ex          # Phoenix core (forms, inputs, icons)
    ├── layouts.ex                  # App shell, flash groups
    └── app_components.ex           # Streamix UI components
```

### Core Contexts

| Context | Module | Responsibility |
|---------|--------|----------------|
| Accounts | `Streamix.Accounts` | Auth, users, roles, scopes |
| IPTV | `Streamix.Iptv` | Providers, channels, movies, series, favorites, history, EPG, sync |
| Billing | `Streamix.Billing` | Plans, subscriptions |
| Cache | `Streamix.Cache` | L1+L2 cache with `fetch/3` stampede prevention |
| AI | `Streamix.Ai` | Gemini/NVIDIA embeddings, Qdrant vector search |
| WatchParty | `Streamix.WatchParty` | Real-time sync, invite codes |
| Queue | `Streamix.Queue` | Broadway/RabbitMQ pipelines (optional) |

### Background Jobs (Oban)

| Worker | Schedule | Queue |
|--------|----------|-------|
| `SyncAllProvidersWorker` | Every 6h | sync |
| `SyncGlobalProviderWorker` | Every 4h | sync |
| `SyncGindexProviderWorker` | Daily 3 AM | sync |
| `SyncEpgWorker` | On demand | sync |
| `IndexEmbeddingsWorker` | Daily 5 AM | ai |
| `CleanupOrphanedDataWorker` | Daily 2 AM | default |
| `SyncSeriesDetailsWorker` | On demand | series_details |

### Key Subsystems

**Stream Proxy** (`StreamController`): Resolves IPTV redirect chains, proxies HLS/TS through Elixir to fix mixed-content and hide credentials. Uses `Req` with `redirect: :manual` to avoid consuming single-use tokens.

**Circuit Breaker** (`XtreamCircuitBreaker`): Per-provider ETS state tracking. Thresholds: 5 errors/60s → OPEN, 3min recovery → HALF_OPEN. Prevents cascade failures.

**Cache** (`Streamix.Cache`): L1 ConCache (30min TTL) → L2 Redis (configurable TTL). Write-through. Pattern-based invalidation via Redis SCAN.

**GIndex** (`Iptv.Gindex`): Multi-endpoint failover, URL caching with TTL, async scraping. Concurrency: 1 (rate limit protection).

## Code Conventions

- **HTTP client:** Always use `Req`. Never HTTPoison, Tesla, or `:httpc`.
- **Icons:** `<.icon name="hero-*">` — never import Heroicons modules directly.
- **Collections:** Always use LiveView streams. Never assign raw lists.
- **Layouts:** All LiveView templates start with `<Layouts.app flash={@flash} current_scope={@current_scope}>`.
- **Context functions:** First arg is `user_id` or `scope` for authorization.
- **CSS:** Tailwind v4 with `@import "tailwindcss"` in app.css. No `@apply`. No daisyUI.
- **JS:** Import vendor deps into app.js. No inline `<script>` tags — use colocated hooks (`:type={Phoenix.LiveView.ColocatedHook}`, name starts with `.`).
- **Forms:** Always use `to_form/2` → `@form`. Never pass changesets to templates.
- **Tests:** Use `start_supervised!/1` for processes. Test element IDs, not raw HTML text.
- **Migrations:** `mix ecto.gen.migration name_in_snake_case` — always use the generator.

## Prohibitions

- **NEVER** commit secrets, API keys, or `.env` files.
- **NEVER** use `live_redirect`, `live_patch` — use `<.link navigate={}>` / `<.link patch={}>`.
- **NEVER** nest multiple modules in one file.
- **NEVER** use `String.to_atom/1` on user input.
- **NEVER** use `@apply` in CSS.
- **NEVER** use `<% Enum.each %>` in templates — use `<%= for item <- @collection do %>`.
- **NEVER** use `Phoenix.View`, `Phoenix.HTML.form_for`, or `Phoenix.HTML.inputs_for`.
- **NEVER** use `phx-update="append"` or `phx-update="prepend"` — use streams.
- **NEVER** access changeset fields in templates — use `@form[:field]`.

## Infrastructure

- **Database:** TimescaleDB (PostgreSQL 17) with pg_trgm for fuzzy search
- **Cache L1:** ConCache (ETS, 30min TTL, per-node)
- **Cache L2:** Redis 7 (distributed, configurable TTL)
- **Vector DB:** Qdrant (semantic search embeddings)
- **Message Queue:** RabbitMQ 4 (optional, for Broadway sync pipelines)
- **HTTP Server:** Bandit
- **HTTP Client:** Req + Finch connection pools (50 size × 4 count)

## Deploy

- **Image:** `ghcr.io/gabrielmaialva33/streamix:latest`
- **Health:** `GET /api/health`
- **Dockerfile:** Multi-stage (Elixir 1.18.2, OTP 27.2.1, Debian bookworm)
- **Infra:** TimescaleDB, Redis, Cloudflare Tunnel

## Reference

For detailed Phoenix/LiveView/Ecto patterns (HEEx interpolation, stream operations, form handling, JS hooks, test patterns), see the inline comments below.

@docs/phoenix-guidelines.md
