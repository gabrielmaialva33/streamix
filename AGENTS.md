# AGENTS.md

Instructions for AI coding agents working on this repository.

## Overview

Streamix is a unified IPTV streaming platform. Elixir 1.18, Phoenix 1.8, LiveView 1.1, TimescaleDB (pg17), Redis 7, Tailwind CSS v4. Aggregates Xtream Codes IPTV providers with Live TV, Movies, Series, GIndex (Google Drive), AI search, and a REST API for mobile clients.

## Dev Environment

```bash
# Prerequisites: Elixir 1.18+ (OTP 27+), Docker

# Start infrastructure (TimescaleDB, Redis, RabbitMQ, Qdrant)
docker compose up -d

# First-time setup
cp .env.example .env
mix setup

# Dev server
mix phx.server

# Dev server with IEx shell
iex -S mix phx.server
```

## Commands

| Command | Purpose | When to use |
|---------|---------|-------------|
| `mix test` | Run full test suite | Before committing |
| `mix test path/to/test.exs` | Run single test file | During development |
| `mix test path/to/test.exs:42` | Run single test by line | Debugging a test |
| `mix test --failed` | Rerun failed tests | After fixing failures |
| `mix precommit` | Compile (warnings=errors) + format + credo + test | Always before committing |
| `mix format` | Format all Elixir files | After code changes |
| `mix credo --strict` | Static analysis | Code quality check |
| `mix ecto.migrate` | Run pending migrations | After adding migrations |
| `mix ecto.reset` | Drop + create + migrate + seed | Full DB reset |
| `mix ecto.gen.migration name_in_snake_case` | Generate migration file | Adding DB changes |
| `mix assets.build` | Compile CSS + JS | Dev asset changes |
| `mix assets.deploy` | Minify + digest for production | Prod builds |

## Testing

- Framework: ExUnit with `Phoenix.LiveViewTest` and `LazyHTML`.
- Test files: `test/` directory, mirroring `lib/` structure.
- Always run `mix precommit` before committing — it compiles with warnings-as-errors, formats, runs credo strict, and runs all tests.
- Use `start_supervised!/1` for processes in tests to ensure cleanup.
- Test element presence by DOM IDs, not raw HTML text content.
- Never use `Process.sleep/1` in tests — use `Process.monitor/1` + `assert_receive`.

## Code Style

### Elixir

- HTTP client: `Req` (already included). Never use HTTPoison, Tesla, or `:httpc`.
- First argument of context functions is `user_id` or `scope` for authorization.
- Predicate functions end with `?`, never start with `is_` (reserve for guards).
- Don't use `String.to_atom/1` on user input.
- Don't nest multiple modules in one file.
- Block expressions (`if`, `case`, `cond`) must bind their result to a variable.

### Phoenix / LiveView

- Access current user via `@current_scope.user`, never `@current_user`.
- Auth: password-based (bcrypt). Roles: `admin`, `customer`, `moderator`.
- Wrap LiveView templates in `<Layouts.app flash={@flash} current_scope={@current_scope}>`.
- Icons: `<.icon name="hero-*">` component. Never import Heroicons modules.
- Forms: use `to_form/2` → `@form[:field]`. Never pass changesets to templates.
- Collections: always use LiveView streams. Never assign raw lists.
- Navigation: `<.link navigate={}>` / `<.link patch={}>`. Never use `live_redirect` / `live_patch`.
- No inline `<script>` tags — use colocated hooks (`.HookName` with `:type={Phoenix.LiveView.ColocatedHook}`).

### CSS / Frontend

- Tailwind CSS v4 with `@import "tailwindcss"` syntax.
- No `@apply`. No daisyUI. No `tailwind.config.js` (v4 doesn't need it).
- Import vendor deps into `app.js` / `app.css`. No external script `src` or link `href` in layouts.
- Design: dark mode default, light mode with Catppuccin Latte palette.

### Database

- TimescaleDB (PostgreSQL 17) with pg_trgm extension for fuzzy search.
- Ecto schema fields use `:string` for both varchar and text.
- Preload associations in queries when accessed in templates.
- Fields set programmatically (`user_id`) must NOT be in `cast/3`.

## Architecture

```
lib/streamix/              # Business logic
├── accounts/              # Auth, users, roles
├── iptv/                  # Providers, channels, movies, series, EPG, GIndex
├── ai/                    # Embeddings, vector search (Qdrant)
├── billing/               # Subscription plans
├── cache.ex               # L1 (ConCache) + L2 (Redis)
├── queue/                 # Broadway + RabbitMQ (optional)
├── watch_party/           # Real-time sync watching
├── workers/               # Oban background jobs
└── rate_limit.ex          # Hammer rate limiting

lib/streamix_web/          # Web layer
├── controllers/api/v1/    # REST API (mobile)
├── controllers/           # Stream proxy, health, sessions
├── live/                  # LiveView pages
│   ├── admin/             # Admin panel
│   ├── content/           # Movie/series detail
│   └── watch_party_live/  # Watch party UI
└── components/            # Phoenix components
```

### Key Patterns

- **L1+L2 Cache**: ConCache (in-memory, 30min TTL) → Redis (distributed). Write-through with stampede prevention.
- **Circuit Breaker**: Per-provider ETS state. 5 errors/60s → open, 3min recovery.
- **Stream Proxy**: Resolves IPTV redirect chains, proxies HLS/TS through Elixir. Uses `redirect: :manual` to avoid consuming single-use tokens.
- **Rate Limiting**: Auth 5 req/min, Stream proxy 60 req/min, API 120 req/min.

## PR Instructions

- Run `mix precommit` and fix all issues before opening a PR.
- Commit messages: concise, focus on "why" not "what".
- Keep PRs focused on a single concern.
- Ensure no compiler warnings (warnings-as-errors is enforced).
- Never commit `.env`, secrets, or API keys.

## Deploy

- Docker multi-stage build (Elixir 1.18.2, OTP 27.2.1).
- Health endpoint: `GET /api/health`.
- Infrastructure: TimescaleDB, Redis, RabbitMQ (optional), Qdrant.
