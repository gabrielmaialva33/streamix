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
- An executable OpenAPI 3 contract for all 25 catalog operations, served as JSON at `/api/v1/openapi.json` with an
  interactive UI at `/api/v1/docs`.
- `GET /api/v1/catalog/movies/:id/sources` and `GET /api/v1/catalog/episodes/:id/sources` list the equivalent playable
  copies of a title, best first, with provider health, raw title, container and the same version badges as the web
  source picker. Torrent copies and copies the stream endpoint would refuse are never listed.
- `GET /api/v1/catalog/series/:id/sources` offers the same per-provider series copies as the web series page, in the
  same order, with their playable season and episode counts.
- "Dramas curtos" at `/browse/reels`: the vertical short-drama series that providers tag with `[Reels] ...`
  categories, with those categories merged by name across every visible provider, category chips, infinite scroll and
  a catalog tab. TV clients get the same list from `GET /api/v1/catalog/reels` (`category`, `page`, `per_page`;
  series cards plus `reel_category`) and the merged categories with counts from
  `GET /api/v1/catalog/reels/categories`.
- "Jogos de hoje": providers with the operator-only `games_enabled` flag feed today's sports schedule (São Paulo time)
  into a rail on `/browse`, each match opening its live channel in the existing player. Finished matches leave the
  list. TV clients get the same matches from `GET /api/v1/catalog/games`.
- Canonical genres: a closed vocabulary of 24 pt-BR genres with stable slugs (`acao`, `ficcao-cientifica`, …) replaces
  the raw provider strings sync used to store ("sci-fi & fantasy", "comédia / drama", reels tropes). Provider genre
  strings and category names ("▶️ Terror & Suspense", "FILMES | Ação e Aventura") map onto it; anything else, such as
  streaming services, quality, language, release shelves, reels categories and adult categories, is never a genre.
  Movies get genres for the first time, from their categories. `Streamix.Catalog.canonicalize_genres/0` converts an
  existing catalog once (run it with the `sync` queue paused).
- Catalog, search and recommendation cards expose `genres: [{slug, name}]` next to the unchanged `genre` string.
- TMDB genres now own a title: the ids already present in TMDB detail responses, GIndex matches and YTS torrents are
  stored and applied to every copy of the same `tmdb_id`, and a nightly job (05:45) backfills the rest, once per
  `tmdb_id`, through a bare uncached request.
- "Todos os provedores" on `/browse/movies` and `/browse/series` finally has a filter: the canonical genres, with
  counts, as a sidebar on desktop and chips on mobile (`?genre=terror`). Provider categories still apply once a
  provider is selected.
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
- Episodes embedded in `GET /api/v1/catalog/series/:id` now carry `season_number`, like the episode detail.
- The home genre filters use canonical slugs and exact matches; before, only "Drama" matched, because the filter
  values were English and compared as substrings of pt-BR genre names.
- EPG sync no longer requests `/xmltv.php` from a provider whose channels declare no EPG id; there is nothing a guide
  could attach to, and panels like that answer 404.
- The web app shows clean titles: provider release noise (`[LEG]`, `[L]`, `4K [Hybrid]`, `(2025) (2025)`, `[Reel]`,
  dotted file names, "Série - S01E01 - " prefixes, channel list numbers) stays in the stored name and leaves the cards,
  hero, detail pages and player title.
- The movie page picks its source with the same picker as the series and episode pages (`?source=<id>`), instead of
  cards showing "Stream <id>" and a category link.
- "Para você" and "Títulos similares" show one card per title, and similar titles no longer include the page's own
  title through another provider's copy.
- "Continuar assistindo" leads an episode with its series and position ("T1 E2") and falls back to the series cover,
  and resumes each title once: the latest copy of a movie (same TMDB id or clean title) and the latest episode of a
  series stand for the others.
- Source badges read `LEG`/`DUB` from the shelf a copy sits on ("▶️ Legendados", "FILMES | Legendados") when its name
  says nothing, and copies of one provider with the same badges are offered once by the web pickers and
  `GET /api/v1/catalog/{movies,episodes}/:id/sources`; playback failover still tries every copy.
- "Lançamentos" stops at the current year, and GIndex reads the last plausible year in a release name, so
  "Blade.Runner.2049.2017" is from 2017.
- One set of web controls: `<.button>` and `<.badge>` variants, pill filter chips with pt-BR counts ("76,1 mil"),
  styled selects, shared page and section headers, one page gutter, an opaque header once scrolled, and one relative
  time ("agora", "há 5 min", "ontem"). On title pages "Assistir" is the only primary action.
- The phone shell's last tab is "Mais" (Guia, Torrents, Assistir juntos, Histórico, provedores, configurações), so it
  reaches what the desktop header offers.
- Search "Todos" previews each type (two rows on phones, one on desktop) with "Ver os N filmes"; the full list and
  "Mostrar mais" live in each type's filter.
- Minha lista uses the poster grid with touch-visible actions, Histórico no longer stacks its type badge on the
  progress bar, and the Guia has compact phone rows and category chips without the "Canais |" prefix.

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
