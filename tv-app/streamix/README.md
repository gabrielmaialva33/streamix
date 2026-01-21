# Streamix TV App

TV application for Streamix built with Lightning TV + SolidJS.

## Overview

This is the Smart TV client for Streamix, designed for:
- LG webOS
- Samsung Tizen
- Android TV
- Fire TV

Connects to the main Streamix server to provide IPTV streaming on big screens.

## Features

- 10-foot UI optimized for remote control navigation
- Fast channel switching with pre-buffering
- Favorites and continue watching sync with main app
- EPG (Electronic Program Guide) display
- Multi-audio track and subtitle support

## Quick Start

```bash
# Install dependencies
npm install

# Development
npm start

# Build for specific platform
TARGET_DEVICE=lg npm run build    # LG webOS
TARGET_DEVICE=tizen npm run build # Samsung Tizen
```

## Building for Devices

### LG webOS

```bash
TARGET_DEVICE=lg npm run build
# Output: dist/lg/
```

### Samsung Tizen

```bash
TARGET_DEVICE=tizen npm run build
# Output: dist/tizen/
```

### Using .env Files

Create `.env`:
```
VITE_TARGET_DEVICE=lg
VITE_STREAMIX_API_URL=https://your-streamix-server.com
```

## Configuration

Set your Streamix server URL in the environment:

```
VITE_STREAMIX_API_URL=https://your-streamix-server.com
```

## Project Structure

```
tv-app/streamix/
├── src/
│   ├── components/     # UI components
│   ├── pages/          # App pages (Home, Player, Settings)
│   ├── api/            # Streamix API client
│   └── utils/          # Utilities
├── device/             # Device-specific configs
│   ├── common/
│   ├── lg/
│   └── tizen/
└── dist/               # Build output
```

## How It Works

- A Vite plugin automatically updates the project configuration based on `TARGET_DEVICE`.
- Device-specific configurations are adjusted in `device/config.ts`.
- The output build is stored in `dist/{device}` (e.g., `dist/lg/` or `dist/tizen/`).

## Running Builds Locally

To preview different builds:

```bash
npx vite preview --outDir dist/lg
npx vite preview --outDir dist/tizen
```

## Related Links

- [Main Streamix Project](../../README.md)
- [Lightning TV Docs](https://lightningtv.dev/)
- [SolidJS Docs](https://www.solidjs.com/)

## License

MIT - Part of the Streamix project
