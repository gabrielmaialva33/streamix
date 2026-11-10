# Changelog

All notable changes to Streamix are documented here.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- A Netflix-style player: chrome, pause screen, episodes panel, gestures and keyboard controls, a startup screen with
  the title's cover and plain-words loading stages, and "fill screen" as the default framing on desktop and phones.
- Playback telemetry records why a session ended (`end_reason`), why an engine was chosen (`engine_reason`) and which
  build the browser ran (`client_revision`).
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

- Fewer titles start on the slow WASM engine: the browser capability check asks about file playback for progressive
  MP4/MKV (it asked about Media Source Extensions, which made iPhones reject files Safari plays natively), and only
  "not supported" rules the native player out; "not smooth" now just lowers the resolution.
- A title page warms the engine its "Assistir" button will use as soon as the page is idle, so phones, which never
  hover, no longer pay the whole AVPlayer runtime load on the first tap.
- A production deploy recreates only the app container. It used to start and recreate dependencies whose image
  changed, so merging an infrastructure image bump restarted the shared Postgres and Redis.
- Production app logs go to journald (`journalctl -t streamix`), so they survive the container being recreated on
  every deploy.
- A title whose provider has to probe its sources opens at once on a startup screen and plays when a source is named;
  a probe that fails, or one slower than its budget while another provider has the title, moves to that provider
  server-side, so the first try plays.
- VOD blocks stream to the viewer while they download, a dropped upstream connection resumes from the first missing
  byte, readahead grows for providers slow to answer, and providers are ranked by how their VOD actually plays.
- Live HLS reuses its synthetic master playlist and prefetches the first live segment.
- Confirmed missing VOD files are hidden for seven days, and buffering metrics count rebuffering only.
- API framework JSON errors under `/api` now use the existing v1 `error.code` / `error.message`
  envelope instead of `errors.detail`. Endpoint-specific errors and success payloads stay compatible.
- Stripe webhook rejections return a constant public message; internal reasons are logged with redaction.

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
- A failed provider health probe no longer marks the provider unavailable on its own: the control-plane rule decides
  (degraded at first, unavailable after three failures in a row or a terminal reason), so a probe that times out
  while the app boots after a deploy shows "instável" at most, not the red "Provedor IPTV indisponível" banner.
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
- Catalog toolbars put the type tabs on a line of their own (the active tab is never cut), name the catalog
  ("Catálogo: IPTV / Google Drive") and the sources ("Fontes: todas"), and no catalog page or search scrolls
  sideways on a phone. Phone grids have two poster columns (three from 540 px) with 14 px titles and a favorite
  button that no longer covers the poster.
- "AO VIVO" is shown only when a programme is on now; other channels say "TV" and "Programação indisponível"
  without a guide. Missing posters show the clean title, and missing team crests a neutral monogram.
- Series episodes show a 16:9 still (or the series art), a progress bar or "Concluído", and titles such as
  "Piloto · T1 E1".
- Plans show prices as "R$ 9,99", statuses in Portuguese and "Assinar plano"; Settings shows the account e-mail
  read-only instead of a change form that did nothing; the Watch Party hub no longer hides under the phone nav.
- 404 and 500 pages render inside the app's layout (styles, a "Página não encontrada" / "Algo deu errado" title, dark
  theme) with a button back home, instead of a bare white page with a missing illustration.
- Prices keep their currency with pt-BR numbers everywhere (public plans, admin plans and billing): "R$ 1.234,56",
  "US$ 10,00", "€ 10,00", where the admin briefly showed every currency as reais.
- The public landing page uses clean titles, the app's 0–5 rating scale and "TV" instead of a fixed "AO VIVO", and
  its cards lead to the title (through login).
- Google Drive title pages share the IPTV title pages' hero, badges, back link and actions, with clean titles and
  nothing under the phone navigation.
- Accessibility: carousel arrows are named and visible on keyboard focus, the gallery preview is a real dialog,
  functional text meets WCAG AA contrast, the phone logo link has a name, login and sign-up have a main landmark,
  and the provider form returns focus to its trigger. axe violations on the audited pages went from 10–23 per page
  to 0–1.
- Meus provedores no longer lists the platform's system providers to regular users (admins still manage them, without
  a delete button); a provider's catalog has a header with its name, a way back and a 44 px "Sincronizar". Torrents,
  Dramas curtos (now with search) and the admin pages (pt-BR intervals, "R$ 0,00", accents) got the same polish.
- The player handles its edges: when the browser blocks autoplay it shows a large play button instead of an endless
  spinner; errors offer "Tentar novamente" (now clickable) and "Voltar"; a resume toast offers "Recomeçar"; the end
  of a movie or last episode offers "Assistir novamente" or "Voltar"; the timeline is a keyboard slider ("Posição do
  vídeo", arrows, Page Up/Down, Home/End); and the update notice moves to the top while a player is open.
- Watch Party rooms on phones keep the header clear and the video visible under a shorter chat sheet; a full room
  disables "Entrar"; copying the invite says "Copiado!"; the paywall returns you to the room or title afterwards.
- The player shows a centered spinner while buffering instead of a red pulsing dot (which read as recording), has
  an "Áudio e legendas" button in the control bar with a quick subtitles on/off (also on the `C` key, restoring
  the last subtitle used), and every control is a 44 px target with a backdrop on phones.
- The Guia on desktop has a readable channel column and a timeline: programme blocks are as wide as their share of
  the visible window, with a "now" marker and the current programme highlighted.
- Minha lista, Histórico, Guia, Planos, Configurações, Watch Party, Torrents and Meus provedores share one page
  header; empty lists share one empty state with an "Explorar catálogo" way out. On phones, a title page puts
  Watch Party, Lista, Trailer and TMDB in one labeled row under "Assistir". Histórico names episodes
  "Série · T1 E1" with the episode title below, and Minha lista moves the type off the poster.
- Minha lista uses the poster grid with touch-visible actions, Histórico no longer stacks its type badge on the
  progress bar, and the Guia has compact phone rows and category chips without the "Canais |" prefix.

### Security

- Watch history, playback progress and favorites are sealed per user: AES-256-GCM rows under a random library key
  that only the user's password (PBKDF2, 600k iterations) or a secret held by their own session can open. Neither the
  database, its backups, Redis, Qdrant, the logs nor the admin panel can tell which content anyone watched. The threat
  model and its limits are in [`docs/privacy.md`](docs/privacy.md).
- Personalization (taste profile, insights, recommendations, personalized shelves) is computed inside the user's
  session and cached in node memory only. The Qdrant `user_profiles` collection and `UpdateUserProfileWorker` are
  gone.
- "Em alta" ranks recent, well-rated titles instead of counting views, which on a small instance would tell who
  watched what.
- Logs never pair a user with content, nor name content: request lines show route patterns (`GET /watch/:type/:id`)
  without `user_id`, streaming logs tag content with a per-boot opaque reference, upstream URLs lose their stream
  ids, and the sample nginx log format drops query strings, `Referer` and client addresses. Stream tokens are
  encrypted instead of signed.
- `playback_sessions` stops recording what a screen plays and deletes slots when playback ends, QoE samples no longer
  store a user, `watch_events` is emptied, ended Watch Party rooms are purged after a day instead of 90, and
  personal-provider VOD bypasses the on-disk block cache.
- The migration is an expand step (new `sealed_watch_progress`/`sealed_favorites` tables, nothing dropped, renamed or
  made stricter), so the previous image survives the deploy window and an image rollback. A later release retires
  the plaintext tables and the cleared columns.
- Upgrading ends every session once: web users and TV/mobile apps log in again, and the API bearer token now carries
  the session's library secret (88 characters). Each user's plaintext history is sealed at their next login; run
  `Streamix.Library.purge_legacy_plaintext/0` to delete what is left.

### Fixed

- Include lazy decoder preparation in the AVPlayer startup budget and preserve remaining recovery time across pauses and watch-party holds.

- Remove native playing and metadata listeners on activation replacement, session changes and player teardown.

- Audio diagnostics no longer reroute or silence native playback; cancelled and timed-out probes release their listeners, captures and audio contexts.

- Reevaluate learned AVPlayer choices after three days, stop learning slow startups, and clear AVPlayer evidence after stable native playback.

- Give AVPlayer bootstrap its own bounded startup budget and try native MP4 once on a first-frame timeout, discarding failed engine memory.

- A terminal playback error is recorded as an error, not as a cancelled or restarted session.
- Playback sessions report the device class (mobile/desktop); it was always `unknown`.
- A playback session that ends because the viewer closed the tab, reloaded or navigated away is still recorded: the
  player sends its summary with `sendBeacon` to `POST /api/qoe/beacon` (session cookie, CSRF token in the body), since
  the LiveView socket is already gone at that point.
- The VOD block cache survives a deploy: on boot it reindexes the blocks already on disk and trims them to
  `VOD_CACHE_MAX_BYTES`. Before, each restart left the previous blocks unreachable and uncounted, so the cache never
  served a block across a deploy and grew past its budget without limit.
- The admin users page lists every user ("Carregar mais"), not only the first twenty.
- Favorites and history keep their type filter in the URL, so back, reload and shared links keep it.
- The PWA install prompt recognizes an iPhone home-screen app as installed (`navigator.standalone`).
- Player toasts and overlays cancel their timers when replaced or when the player closes.
- Prices on the plans and billing pages are formatted in the plan's currency instead of always "R$".
- The first tap on a phone shows the player controls at once.
- A movie or episode whose native playback fails before its first frame (an aborted or unexplained media error, or a
  rejected `play()`) now tries the AVPlayer engine once instead of ending on an error screen; before, only decode and
  unsupported-format errors did. Playback telemetry records the failure as `error_code` (`media_decode`,
  `media_unsupported`, `media_aborted`, `media_network`, `media_unknown`, `play_rejected`).
- `POST /api/v1/auth/register` with an email already in use answers `422` with `email: has already been taken`;
  it crashed into a `500` because a validation option was not text.
- Rate-limit buckets are separate per route group. They all shared one counter per client, so a viewer's HLS
  segments spent the allowance of the stream proxy, the login and the QoE beacon; and the stream proxy, which
  answers every range request of a household's devices, now allows 600 requests a minute instead of 60.
- The Prometheus reporter no longer grows without bound when nothing scrapes `/metrics`: raw distribution samples
  are folded into their buckets every minute (production held 17.8 million samples, 3.3 GB, after five days).
- A live channel that answered 404 stays marked through provider syncs for its 24-hour recheck window, and the
  player says it is off the air instead of retrying it. Every sync used to clear the mark, since panels keep
  listing channels whose stream is gone, and viewers looped on such a channel.
- The nightly embeddings run reads the catalog in pages instead of one query that held a database connection past
  its 15-second limit.
- Every active Xtream provider's TV guide is refreshed hourly when due. Before, a guide only refreshed when someone
  opened the channel page filtered to that provider, so a non-global provider's guide ran out and its channels showed
  no programs.
- The "play" button shown when the browser blocks autoplay, and the replay button at the end of a title, start the
  video again; both threw `this.play is not a function` after a player refactor.

### Security

- `return_to` links are followed only when they point to a path on this site. Five pages accepted `/\host`, which
  browsers treat as `//host`, so a crafted link could send a viewer to another site.
- Logged failure reasons go through `Streamix.SafeLog`, so upstream URLs and credentials inside a reason no longer
  reach the logs as written.

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
