# Streamix

Phoenix + LiveView streaming platform that aggregates multiple Xtream Codes providers into a single web application and
REST API. Streamix supports live channels, movies, series, favorites, history, watch progress, premium access, watch
parties, and optional AI-assisted search / recommendations.

[Portuguese / Portugues](README.pt.md)

## What This Repo Contains

This repository contains:

- the Phoenix backend
- the LiveView web client
- the stream proxy and signed stream-token flow
- the mobile / TV-facing REST API
- the optional AI, Redis, Qdrant, RabbitMQ, and GIndex integrations

It does **not** contain the older standalone TV app that used to live in this repository. That frontend was extracted
to a separate repo.

## Feature Summary

### Core product

- Multi-provider Xtream Codes aggregation
- Optional global provider shared across users
- Optional GIndex ingestion for Google Drive-backed content
- Live TV, movies, series, seasons, and episodes
- Favorites, watch history, and watch progress
- EPG sync plus now/next queries
- Premium plans, subscriptions, and gated playback
- Admin dashboard with user and plan management

### Playback and delivery

- Signed stream URLs for channels, movies, and episodes
- Phoenix stream proxy for mixed-content / credential-hiding flows
- Live stream multiplexer for shared upstream consumption
- HLS, MPEG-TS, and AVPlayer-oriented playback support
- Circuit breaker protection for unstable upstream providers

### Real-time and UX

- Watch parties with synced playback, presence, and room chat
- Responsive LiveView UI
- PWA manifest + service worker
- Offline metadata sync hooks for favorites and history
- Theme toggle with dark mode by default

### Optional AI surfaces

- Embeddings via Gemini or NVIDIA
- Qdrant-backed semantic search
- Similar-content recommendations
- User taste profiling and personalized home sections

If AI services are not configured, Streamix falls back to normal text search where supported.

## Stack

- Elixir `~> 1.18`
- OTP 27
- Phoenix `~> 1.8.2`
- Phoenix LiveView `~> 1.1.0`
- Ecto SQL `~> 3.13`
- TimescaleDB / PostgreSQL 17
- Redis 7
- Qdrant (optional)
- RabbitMQ 4 + Broadway (optional)
- Oban 2.18
- Req + Finch
- Tailwind CSS v4
- esbuild
- npm packages in `assets/`

## Repository Layout

```text
lib/streamix/
  access/        permissions and grants
  accounts/      users, roles, session tokens, settings, IP tracking
  ai/            embeddings, Qdrant, semantic search, user analytics
  billing/       plans and subscriptions
  iptv/          providers, sync, catalog, EPG, stream proxy, GIndex
  library/       shared content references
  queue/         optional RabbitMQ + Broadway path
  watch_party/   rooms, participants, messages, room server
  workers/       Oban workers

lib/streamix_web/
  controllers/   HTML, stream proxy, health, API v1
  live/          landing, auth, catalog, admin, watch party, providers
  components/    layouts and reusable UI
  plugs/         CORS, CSP nonce, API key auth, rate limiting

assets/
  css/app.css
  js/app.js
  js/hooks/
```

## Quick Start

### Requirements

- Docker
- Elixir 1.18+
- OTP 27+
- Node.js 20+ and npm

### 1. Start infrastructure

```bash
docker compose up -d
```

This brings up:

- TimescaleDB / PostgreSQL 17
- Redis
- RabbitMQ
- Qdrant

RabbitMQ and Qdrant are optional at runtime, but the compose file includes them for local development.

### 2. Configure environment

```bash
cp .env.example .env
```

Minimum values you must set before `mix setup`:

- `ADMIN_PASSWORD`
- `PROVIDER_ENCRYPTION_KEY`

Important environment variables:

- `DATABASE_URL` - defaults to `ecto://streamix:streamix@localhost/streamix_dev`
- `TEST_DATABASE_URL` - optional; inferred from `DATABASE_URL` when missing
- `REDIS_URL`
- `GLOBAL_PROVIDER_*` - optional shared provider
- `GINDEX_ENABLED` / `GINDEX_URL` - optional GIndex integration
- `TMDB_API_TOKEN` - optional metadata enrichment
- `GEMINI_API_KEY` or `NVIDIA_API_KEY` - optional embeddings
- `QDRANT_URL` - required for semantic search
- `RABBITMQ_ENABLED` - optional Broadway path
- `API_KEYS` - API keys for external clients

In production you also need:

- `SECRET_KEY_BASE`
- `LIVE_VIEW_SIGNING_SALT`
- `PHX_HOST`

### 3. Install frontend dependencies

```bash
cd assets && npm ci && cd ..
```

`assets/node_modules` is ignored, and `mix setup` does not run `npm ci` for you.

### 4. Setup the app

```bash
mix setup
```

`mix setup` runs:

- `mix deps.get`
- `mix ecto.setup`
- `mix assets.setup`
- `mix assets.build`

Because `ecto.setup` runs seeds, missing `ADMIN_PASSWORD` will fail the setup.

### 5. Start Streamix

```bash
mix phx.server
```

Open [http://localhost:4000](http://localhost:4000).

## Useful Commands

```bash
mix test
mix test path/to/test.exs
mix test path/to/test.exs:42

mix credo --strict
mix quality
mix precommit

mix ecto.migrate
mix ecto.reset

mix assets.build
mix assets.deploy
```

## Main Runtime Surfaces

### Browser routes

- `/` landing page
- `/plans`
- `/login`, `/register`, `/settings`
- `/browse`, `/browse/movies`, `/browse/series`
- `/providers`, `/providers/:provider_id/...`
- `/favorites`, `/history`
- `/gindex/...`
- `/party`, `/party/:invite_code`, `/party/:invite_code/watch`
- `/watch/:type/:id`
- `/admin`, `/admin/plans`, `/admin/users`

### REST API

Main endpoints live under `/api/v1`:

- `/auth/register`, `/auth/login`, `/auth/logout`, `/auth/me`
- `/catalog/...`
- `/search/...`
- `/recommendations/...`
- `/favorites`
- `/history`
- `/epg/...`
- `/telemetry/playback`
- `/providers`

The health endpoint is `GET /api/health`.

## Architecture Notes

- `Streamix.Iptv.XtreamClient` is the single entrypoint for Xtream provider HTTP calls.
- `Streamix.Iptv.Gindex.Client` + `EndpointManager` handle GIndex endpoint selection and pacing.
- `Streamix.Cache` provides ConCache L1 + Redis L2 caching.
- `Streamix.AI.SemanticSearch` and `Streamix.AI.UserAnalytics` power optional AI features.
- `Streamix.WatchParty.RoomServer` coordinates live watch-party playback state.
- `StreamixWeb.StreamToken` signs stream URLs so raw upstream credentials are not exposed.

## Docker Image

The repo builds and publishes:

```text
ghcr.io/gabrielmaialva33/streamix:latest
```

The current GitHub Actions workflow builds and pushes the Docker image on pushes to `master`.

## Contributing, Security, and License

- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md)
- Security: [SECURITY.md](SECURITY.md)
- Agent / repo rules: [AGENTS.md](AGENTS.md)
- License: [MIT](LICENSE)
