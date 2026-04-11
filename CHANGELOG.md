# Changelog

All notable changes to Streamix will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.0] - 2025-01-21

### Added

- **Circuit Breaker Pattern** - Netflix-style resilience for IPTV providers with automatic failover
- **Content Recommendations** - SemanticSearch integration for "Similar Titles" in movie/series detail pages
- **Next Episode Pre-fetch** - Automatic pre-loading of next episode metadata and stream URL for seamless binge-watching
- **PWA Update Notification** - Toast notification when new service worker is available with one-click update
- **Offline Metadata Caching** - IndexedDB storage for favorites and watch history, accessible offline
- **Robust Infinite Scroll** - IntersectionObserver-based sentinel pattern with 400px early trigger
- **Theme Persistence** - Dark/light mode preference saved to localStorage with instant sync

### Changed

- Migrated infinite scroll from `phx-viewport-bottom` to sentinel pattern for better reliability
- OfflineSync hook now integrated in history and favorites LiveViews
- Theme toggle initializes from localStorage before hydration (no flash)

### Fixed

- CSP nonces now properly applied to app.js script tag
- Cloudflare rocket-loader compatibility with updated CSP domains
- Light mode contrast improved for WCAG AA accessibility compliance
- SQL LIKE injection vulnerability in search functions
- Theme initialization handler added to all LiveViews

### Security

- Implemented Content Security Policy with nonces for inline scripts
- Added CORS protection with Vite development support
- Secure cookie settings and improved session security

## [1.3.0] - 2025-01-15

### Added

- Image proxy for Cloudflare CDN caching (ImageProxy module)
- Dark/light mode toggle with CSS variables
- Batch telemetry for sync operations
- Security audit tools

### Changed

- Translated auth messages to PT-BR
- CSP updated for Cloudflare analytics and streaming

### Fixed

- O(n²) list concatenation in sync engine
- Deprecated on_play attribute in search

### Security

- Safe mode for binary_to_term deserialization
- Explicit content-type for stream responses

## [1.2.0] - 2025-01-10

### Added

- PWA support with service worker, manifest, and app icons
- Standalone mode CSS optimizations for installed app
- ETS-based cache with atomic cleanup

### Fixed

- Player loading indicator and error display bugs

### Changed

- Refactored GIndex anime/series sync logic
- Extracted generic content sync to Helpers module

### Security

- Removed hardcoded password fallback from seeds
- Moved signing_salt to runtime config via env var
- Reduced stream token TTL from 24h to 2h
- Constant-time comparison for API key auth
- SQL injection prevention in ILIKE queries

## [1.1.0] - 2025-01-05

### Added

- Tizen TV app with AVPlay/HTML5 player support
- Netflix-inspired player with metadata probe
- Dynamic audio/subtitle track selection
- TV-optimized search with native keyboard support
- Storage utility for favorites and watch history

### Fixed

- Channel card navigation using link instead of phx-click
- Various player and UI fixes for TV platform

## [1.0.0] - 2025-01-01

### Added

- Initial release of Streamix
- IPTV provider management with M3U sync
- Live channels, movies, and series browsing
- Favorites and watch history tracking
- Magic link authentication (passwordless)
- Phoenix 1.8 with LiveView streams
- Tailwind CSS v4 styling

[1.4.0]: https://github.com/mrootx/streamix/compare/v1.3.0...v1.4.0

[1.3.0]: https://github.com/mrootx/streamix/compare/v1.2.0...v1.3.0

[1.2.0]: https://github.com/mrootx/streamix/compare/v1.1.0...v1.2.0

[1.1.0]: https://github.com/mrootx/streamix/compare/v1.0.0...v1.1.0

[1.0.0]: https://github.com/mrootx/streamix/releases/tag/v1.0.0
