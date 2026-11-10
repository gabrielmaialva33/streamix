# Streamix frontend assets

This directory contains the browser source code compiled by Phoenix. It is not a
standalone frontend application: `mix assets.build` turns these files into the
bundles served from `priv/static/assets/`.

## Structure

```text
css/
├── app.css            # Tailwind entrypoint; imports the files below in cascade order
├── platform.css       # Browser and iOS/WebKit baseline fixes
├── theme.css          # Design tokens, base rules, and shared utilities
├── catalog.css        # Browse navigation, grids, cards, and loading states
├── guide.css          # Live TV guide presentation
├── media_shelves.css  # Horizontal catalog shelves
├── motion.css         # Transitions and content animations
├── player.css         # Player and touch-control presentation
├── pwa.css            # Installed-app and safe-area behavior
├── accessibility.css  # Reduced-motion behavior
└── surfaces.css       # Watch party, view transitions, and auth surfaces

js/
├── app.js             # Thin browser entrypoint
├── bootstrap/         # LiveView and document-level browser setup
├── core/              # Framework-agnostic browser primitives
├── hooks/             # Phoenix LiveView hooks
├── media/             # Codec, buffering, stream, and decoder integrations
├── player/            # Playback state, policy, controls, and UI
├── pwa/               # Install, cache, offline, and service-worker integration
├── watch_party/       # Party playback policy, synchronization, and status
├── telemetry/         # Privacy-bounded client diagnostics
├── test/              # Node unit tests
└── smoke/             # Browser/PWA smoke suites

vendor/                # Checked-in browser dependencies loaded by the bundle
patches/               # npm dependency patches applied after install
```

The service worker source is `priv/sw.js`; its controller serves it with release-aware
cache headers. AVPlayer runtime artifacts live in `priv/static/avplayer/`, with
stable public URLs outside the digested esbuild output. Do not duplicate either
under `assets/js/`. The classic service worker has no module import of the browser
logger: its two `console.warn` calls are the documented exception.

## Commands

Run from this directory:

```bash
npm ci
npm run lint
npm test -- --test-concurrency=4
npm run budget:assets
npm run smoke:player
cd ..
./scripts/test-pwa-chromium.sh
```

Run `mix assets.build` from the repository root for the normal development
bundle and `mix assets.deploy` for the minified, digested production bundle.
The player smoke needs either `STREAMIX_SMOKE_STORAGE_STATE` or the
`STREAMIX_SMOKE_EMAIL` / `STREAMIX_SMOKE_PASSWORD` pair. Set
`STREAMIX_SMOKE_URL` to target a specific watch route; otherwise it discovers a
current public movie in production. Numeric watch routes provide their content
ID automatically, while non-standard routes also need
`STREAMIX_SMOKE_CONTENT_ID`.


Lint configuration lives in the repository-root `biome.json` and covers browser
JS, Node smoke scripts (`.cjs`/`.mjs`), and `priv/sw.js` with environment overrides.
Smoke scripts retain their existing formatting. Node tests include nested test
folders and default to four concurrent files. Run tests in a memory-capped scope
as described in the repository's agent instructions. Asset budgets require a
fresh minified build; lint, Node tests, and asset sizes do not establish browser
playback correctness.

## Media capability dataset

`configurationFromPlayerElement` reads these keys from `#video-player-container` at startup.
They are hints supplied by the server, not client-owned playback state. Missing
hints retain a generic device probe; its defaults are **not measured title metadata**.

| HTML attribute | JS dataset key | Type / default | Current server origin |
| --- | --- | --- | --- |
| `data-container` | `container` | String; `webm` for WebM stream, otherwise `mp4` | Normalized movie/episode `container_extension`; omitted when absent |
| `data-video-codec` | `videoCodec` | RFC 6381 string; `avc1.640028` | Not available; omitted |
| `data-audio-codec` | `audioCodec` | RFC 6381 string; `mp4a.40.2` | Not available; omitted |
| `data-width` | `width` | Positive pixels; 1920 | Not available; omitted |
| `data-height` | `height` | Positive pixels; 1080 | Not available; omitted |
| `data-bitrate` | `bitrate` | Positive video bits/s; 8,000,000 | Not available; omitted |
| `data-framerate` | `framerate` | Positive frames/s; 30 | Not available; omitted |

Cached track labels and TMDB presentation data are not codec/resolution evidence.
Do not add dataset aliases or infer those values from a title. Updates to this
contract require the HEEx-to-parser test in `player_components_test.exs`.

## Convenções

1. Arquivos JS em snake_case; classes em PascalCase; funções/variáveis em camelCase; constantes de contrato em UPPER_SNAKE_CASE.
2. Imports relativos devem incluir `.js`; barrels devem apontar explicitamente para `index.js`.
3. Preferir named exports para módulos internos; reservar default para hooks/barrels que o loader exige. Evitar exportar a mesma API das duas formas sem consumidor real.
4. Hooks conectam lifecycle Phoenix, DOM e colaboradores; não acumulam política de engine, rede ou persistência.
5. `controller` possui um recurso/lifecycle; `coordinator` combina colaboradores; `policy` é pura; `adapter` traduz API. Documentar exceções e o owner do teardown.
6. Escolher classe ou factory por estado/ownership, preservando o contrato; não criar duas implementações equivalentes.
7. Todo recurso assíncrono tem owner e cancelamento/disposer; `destroy` é idempotente e callbacks tardios verificam sessão vigente.
8. Prazos, memoização de imports e emitters usam primitivas compartilhadas com semântica explícita; retry budgets permanecem no domínio.
9. Ler/validar datasets na fronteira; documentar atributo, tipo, default, origem e atualização. Separar dados do servidor de estado escrito pelo cliente.
10. Compartilhar predicados de browser/PWA em `core`; não confundir touch, hover, mobile e standalone.
11. Logging usa logger e níveis; telemetria usa payload limitado e sanitização comum, sem URLs/credenciais. SW pode ter adaptação própria documentada.
12. Cores semânticas vêm de tokens; contraste de overlays de vídeo pode usar tokens específicos. Preservar ordem dos imports CSS e Tailwind v4.
13. Testes comportamentais importam código real e injetam relógio/ambiente; regex de fonte verifica arquitetura, não integração renderizada.
14. Manter gates explícitos para JS, smoke, SW e CSS; executar Node com concorrência limitada. Build/browser são validações distintas do lint/unitário.
15. Remover export/selector somente após conferir consumidores, dinâmicos e contratos; documentar exceções deliberadas em vez de manter código especulativo.
