<h1 align="center">
  <br>
  <img src=".github/assets/web-data.png" alt="Streamix" width="200">
  <br>
  Streamix - Unified IPTV Streaming Platform
  <br>
</h1>

<p align="center">
  <strong>All your IPTV providers in one cinematic, intelligent interface. Live TV, Movies, Series, and more.</strong>
</p>

<p align="center">
  <a href="README.pt.md">Portugues</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Elixir-1.18+-purple?style=flat&logo=elixir" alt="Elixir" />
  <img src="https://img.shields.io/badge/Phoenix-1.8+-orange?style=flat&logo=phoenix-framework" alt="Phoenix" />
  <img src="https://img.shields.io/badge/LiveView-1.1+-blue?style=flat&logo=phoenix-framework" alt="LiveView" />
  <img src="https://img.shields.io/badge/TimescaleDB-pg17-blue?style=flat&logo=postgresql" alt="TimescaleDB" />
  <img src="https://img.shields.io/badge/Redis-7+-red?style=flat&logo=redis" alt="Redis" />
  <img src="https://img.shields.io/badge/Tailwind-v4-38bdf8?style=flat&logo=tailwindcss" alt="Tailwind CSS" />
  <img src="https://img.shields.io/badge/PWA-Ready-5A0FC8?style=flat&logo=pwa" alt="PWA Ready" />
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat&logo=appveyor" alt="License" />
  <img src="https://img.shields.io/badge/Made%20with-Love%20by%20Maia-red?style=flat&logo=appveyor" alt="Made with Love" />
</p>

<br>

<p align="center">
  <a href="#sparkles-features">Features</a>&nbsp;&nbsp;&nbsp;|&nbsp;&nbsp;&nbsp;
  <a href="#art-architecture">Architecture</a>&nbsp;&nbsp;&nbsp;|&nbsp;&nbsp;&nbsp;
  <a href="#computer-technologies">Technologies</a>&nbsp;&nbsp;&nbsp;|&nbsp;&nbsp;&nbsp;
  <a href="#package-installation">Installation</a>&nbsp;&nbsp;&nbsp;|&nbsp;&nbsp;&nbsp;
  <a href="#electric_plug-usage">Usage</a>&nbsp;&nbsp;&nbsp;|&nbsp;&nbsp;&nbsp;
  <a href="#memo-license">License</a>
</p>

<br>

## :sparkles: Features

### Content Management

- **Multi-Provider Aggregation** - Connect multiple Xtream Codes IPTV providers (global or private per user)
- **Background Sync** - Automatic synchronization of Live TV, Movies, and Series via Oban scheduled jobs
- **GIndex Integration** - Stream movies and series directly from Google Drive with multi-endpoint failover
- **Unified Search** - Search across all providers with pg_trgm fuzzy matching and AI semantic search
- **Favorites & Watch History** - Track what you love and resume where you left off
- **TMDB Enrichment** - Automatic metadata, posters, and descriptions from The Movie Database
- **EPG (Electronic Program Guide)** - Live program info with caching and now/next queries

### Streaming Engine

- **Stream Proxy** - HTTP-to-HTTPS proxy to bypass mixed-content blocks (HLS/MPEG-TS)
- **Stream Multiplexer** - Single upstream connection serving multiple downstream clients
- **Circuit Breaker** - Netflix-style resilience per provider (open/half-open/closed states)
- **Format Detection** - Automatic handling of m3u8 and ts stream formats
- **Error Recovery** - Automatic reconnection for unstable streams
- **Multi-Format Playback** - Live Streams, VOD Movies, and Series Episodes

### AI-Powered

- **Semantic Search** - Gemini/NVIDIA NIM embeddings stored in Qdrant vector database
- **Smart Recommendations** - Content similarity, featured picks, and personalized insights
- **Fuzzy Matching** - pg_trgm trigram search for typo tolerance

### User Experience

- **Cinematic UI** - Dark mode (default) + Light mode with Catppuccin Latte palette
- **Responsive Design** - Optimized for Desktop, Tablet, and Mobile
- **LiveView SPA** - App-like navigation without page reloads
- **Watch Party** - Real-time synchronized watching with invite codes
- **PWA Support** - Install as native app on any device with offline metadata caching
- **Keyboard Shortcuts** - YouTube-style player controls

### Mobile API

- **REST API v1** - Full-featured API for mobile/external clients
- **Auth Endpoints** - Register, login, logout with bearer token auth
- **Complete Catalog** - Browse, search, stream, favorites, history, EPG
- **Telemetry** - Playback analytics and monitoring
- **Rate Limited** - Per-endpoint throttling (Hammer)

### Admin Panel

- **Dashboard** - System overview and management
- **Plan Management** - Create and manage subscription plans
- **User Management** - Role-based access (admin, moderator, customer)

### Infrastructure

- **L1+L2 Cache** - ConCache (in-memory) + Redis (distributed) with write-through
- **Broadway + RabbitMQ** - Optional distributed sync pipeline (falls back to Oban)
- **Rate Limiting** - Per-endpoint throttling with Hammer
- **AES-256-GCM Encryption** - Provider credentials encrypted at rest
- **CSP Nonces** - Content Security Policy with dynamic nonces
- **Health Check** - `/api/health` endpoint for container orchestration

<br>

## :art: Architecture

### High-Level Overview

```mermaid
graph TD
    User[User / Client]

    subgraph "Streamix Platform"
        LB[Phoenix Endpoint]
        LV[LiveView UI]
        API[REST API v1]
        Proxy[Stream Proxy / Multiplexer]
        CB[Circuit Breaker]
        Sync[Oban Workers]
        Broadway[Broadway Pipeline]
    end

    subgraph "Cache Layer"
        L1[(L1: ConCache)]
        L2[(L2: Redis)]
    end

    subgraph "Data Layer"
        DB[(TimescaleDB pg17)]
        RMQ[RabbitMQ]
        QD[Qdrant Vector DB]
    end

    subgraph "External"
        P1[IPTV Providers]
        TM[TMDB]
        GI[GIndex / GDrive]
        AI[Gemini / NVIDIA NIM]
    end

    User -->|HTTPS| LB
    LB --> LV
    LB --> API
    LB --> Proxy

    LV --> L1
    L1 -->|Miss| L2
    L2 -->|Miss| DB

    LV --> CB
    CB --> P1

    Sync --> RMQ
    RMQ --> Broadway
    Broadway -->|Bulk Insert| DB
    Sync -->|Enrichment| TM
    Sync -->|Embeddings| AI
    AI -->|Store| QD

    Proxy -->|HLS/TS| P1
    Sync -->|Scrape| GI
```

### Cache Flow (L1 + L2)

```mermaid
sequenceDiagram
    participant C as Client
    participant L1 as L1 Cache (ConCache)
    participant L2 as L2 Cache (Redis)
    participant DB as TimescaleDB

    C->>L1: Get Data
    alt L1 Hit
        L1-->>C: Return Cached Data
    else L1 Miss
        L1->>L2: Get Data
        alt L2 Hit
            L2-->>L1: Return & Populate L1
            L1-->>C: Return Data
        else L2 Miss
            L2->>DB: Query Database
            DB-->>L2: Return & Cache (TTL)
            L2-->>L1: Populate L1 (Short TTL)
            L1-->>C: Return Data
        end
    end
```

<br>

## :computer: Technologies

### Core

| Technology                                                | Version | Description                           |
|-----------------------------------------------------------|---------|---------------------------------------|
| [Elixir](https://elixir-lang.org/)                        | 1.18+   | Concurrent, fault-tolerant runtime    |
| [Phoenix](https://www.phoenixframework.org/)              | 1.8+    | Real-time web framework               |
| [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/) | 1.1+    | Server-rendered reactive UI           |
| [OTP](https://www.erlang.org/)                            | 27+     | Supervision trees and fault tolerance |
| [Bandit](https://hexdocs.pm/bandit/)                      | 1.0+    | HTTP/2 server                         |

### Data

| Technology                                       | Description                                      |
|--------------------------------------------------|--------------------------------------------------|
| [TimescaleDB](https://www.timescale.com/) (pg17) | PostgreSQL with time-series extensions + pg_trgm |
| [Redis](https://redis.io/) 7+                    | L2 distributed cache                             |
| [Qdrant](https://qdrant.tech/)                   | Vector database for semantic search              |
| [Ecto](https://hexdocs.pm/ecto/)                 | Database queries and migrations                  |

### Background Processing

| Technology                                | Description                                              |
|-------------------------------------------|----------------------------------------------------------|
| [Oban](https://getoban.pro/)              | Background jobs with cron scheduling                     |
| [Broadway](https://hexdocs.pm/broadway/)  | High-throughput data pipelines (optional, with RabbitMQ) |
| [ConCache](https://hexdocs.pm/con_cache/) | ETS-based L1 in-memory cache                             |

### Frontend

| Technology                                     | Description                          |
|------------------------------------------------|--------------------------------------|
| [Tailwind CSS](https://tailwindcss.com/) v4    | Utility-first styling                |
| [Catppuccin](https://catppuccin.com/)          | Color palette (Latte for light mode) |
| [Heroicons](https://heroicons.com/)            | SVG icons                            |
| [hls.js](https://github.com/video-dev/hls.js/) | HLS video playback                   |

### External Services

| Service                                                                    | Description                       |
|----------------------------------------------------------------------------|-----------------------------------|
| [TMDB](https://www.themoviedb.org/)                                        | Movie/series metadata and posters |
| [Gemini](https://ai.google.dev/) / [NVIDIA NIM](https://build.nvidia.com/) | AI embeddings for semantic search |
| [GIndex](https://github.com/LeeluPrad662/G-Index)                          | Google Drive content indexing     |

### Quality & Security

| Tool                                      | Description                                |
|-------------------------------------------|--------------------------------------------|
| [Hammer](https://hexdocs.pm/hammer/)      | Rate limiting                              |
| [Sobelow](https://hexdocs.pm/sobelow/)    | Phoenix-focused security static analysis   |
| [mix_audit](https://hexdocs.pm/mix_audit/)| Dependency vulnerability scanner           |
| [Credo](https://hexdocs.pm/credo/)        | Code style and refactoring hints           |
| [Dialyxir](https://hexdocs.pm/dialyxir/)  | Success typing / static analysis           |
| [ExUnit](https://hexdocs.pm/ex_unit/)     | Testing framework                          |

<br>

## :package: Installation

### Prerequisites

- **[Elixir](https://elixir-lang.org/install.html)** 1.18+ (with OTP 27+)
- **[Docker](https://www.docker.com/)** (for infrastructure services)

### Quick Start

1. **Clone and enter**

```bash
git clone https://github.com/gabrielmaialva33/streamix.git
cd streamix
```

2. **Start infrastructure**

```bash
docker compose up -d  # TimescaleDB, Redis, RabbitMQ, Qdrant
```

3. **Configure environment**

```bash
cp .env.example .env
# Edit .env with your credentials (IPTV provider, TMDB API key, etc.)
```

If `TEST_DATABASE_URL` is not set, the test environment automatically derives a
sibling `*_test` database from `DATABASE_URL`.

4. **Setup and run**

```bash
mix setup    # deps, database, assets
mix phx.server
```

5. **Open** [http://localhost:4000](http://localhost:4000)

### Docker Production

Pre-built image on GHCR:

```bash
docker pull ghcr.io/gabrielmaialva33/streamix:latest

docker run -p 4000:4000 \
  -e DATABASE_URL="ecto://user:pass@host/streamix" \
  -e TEST_DATABASE_URL="ecto://user:pass@host/streamix_test" \
  -e SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  ghcr.io/gabrielmaialva33/streamix:latest
```

Or build locally:

```bash
docker build -t streamix .
docker run -p 4000:4000 -e DATABASE_URL="..." -e SECRET_KEY_BASE="..." streamix
```

<br>

## :electric_plug: Usage

### Getting Started

1. **Register** an account at `/register`
2. Navigate to **Providers** and add your Xtream Codes credentials
3. Streamix automatically syncs channels, movies, and series in the background
4. Browse, search, and watch content across all your providers

### Content Types

- **Live TV** - Browse by category, search channels, click to watch
- **Movies** - VOD library with TMDB metadata and poster art
- **Series** - Full series with seasons and episodes
- **GIndex** - Google Drive content (movies, series, anime)

### Watch Party

Create a watch party to sync playback with friends using invite codes.

### Mobile / External Players

Use the REST API at `/api/v1/` with bearer token authentication. See API docs for available endpoints.

### PWA

Install Streamix as a native app:

- **Chrome/Edge**: Click install icon in address bar
- **Android**: Menu > "Add to Home screen"
- **iOS Safari**: Share > "Add to Home Screen"

<br>

## :memo: License

This project is under the **MIT** license. See [LICENSE](./LICENSE) for details.

<br>

## :busts_in_silhouette: Author

<p align="center">
  <img src="https://avatars.githubusercontent.com/u/26732067" alt="Maia" width="100">
</p>

Made with Love by **Maia**

- Email: [gabrielmaialva33@gmail.com](mailto:gabrielmaialva33@gmail.com)
- GitHub: [@gabrielmaialva33](https://github.com/gabrielmaialva33)

<br>

<p align="center">
  <img src="https://raw.githubusercontent.com/gabrielmaialva33/gabrielmaialva33/master/assets/gray0_ctp_on_line.svg?sanitize=true" />
</p>

<p align="center">
  &copy; 2024-2026 <a href="https://github.com/gabrielmaialva33/" target="_blank">Maia</a>
</p>
