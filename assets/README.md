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
├── telemetry/         # Privacy-bounded client diagnostics
├── test/              # Node unit tests
└── smoke/             # Browser/PWA smoke suites

vendor/                # Checked-in browser dependencies loaded by the bundle
patches/               # npm dependency patches applied after install
```

The service worker and AVPlayer runtime artifacts intentionally live in
`priv/static/`, because they must keep stable public URLs outside the digested
esbuild output. Do not duplicate those artifacts under `assets/js/`.

## Commands

Run from this directory:

```bash
npm ci
npm run lint
npm test
npm run budget:assets
npm run smoke:player
cd ..
./scripts/test-pwa-chromium.sh
```

Run `mix assets.build` from the repository root for the normal development
bundle and `mix assets.deploy` for the minified, digested production bundle.
The player smoke targets `STREAMIX_SMOKE_URL` and needs either
`STREAMIX_SMOKE_STORAGE_STATE` or the `STREAMIX_SMOKE_EMAIL` /
`STREAMIX_SMOKE_PASSWORD` pair when that route requires authentication.
