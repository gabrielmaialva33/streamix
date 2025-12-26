# Streamix Project Context

## Overview
Streamix is a Phoenix-based web application designed to manage and stream IPTV content. It allows users to register, manage IPTV providers, and synchronize/view channels from those providers.

## Tech Stack
*   **Language:** Elixir (~> 1.15)
*   **Framework:** Phoenix (~> 1.8.2)
*   **Database:** PostgreSQL (via Ecto SQL)
*   **Frontend:** Phoenix LiveView (~> 1.1.0), Tailwind CSS (~> 0.3)
*   **HTTP Client:** Req (~> 0.5)
*   **Authentication:** Custom implementation using `bcrypt_elixir` (standard `phx.gen.auth` pattern)

## Architecture
The application follows the standard Phoenix umbrella-less structure:

### Core Logic (`lib/streamix/`)
*   **Accounts:** Handles user registration, session management, and authentication.
*   **Iptv:** The core domain context.
    *   `Provider`: Represents an external IPTV service (Xtream Codes API mostly supported via `get.php` and `player_api.php`).
    *   `Channel`: Represents individual TV channels/streams synced from a provider.
    *   `Client`: Uses `Req` to communicate with IPTV providers (fetches playlists and account info).
    *   `Parser`: (Implied) Handles parsing of M3U/JSON responses from providers.

### Web Interface (`lib/streamix_web/`)
*   **Controllers:** Standard controllers for Auth (`UserRegistration`, `UserSession`) and Pages (`PageController`).
*   **LiveView:** The interactive UI is built with LiveView (though specific LiveViews weren't deep-dived, the dependencies and structure confirm this).
*   **Router:** Defined in `lib/streamix_web/router.ex`, protecting routes via authentication pipelines.

## Key Entities & Database Schema
*   **User:** Standard auth fields (email, password_hash).
*   **Provider:**
    *   `name`, `url`, `username`, `password` (redacted).
    *   `is_active`, `last_synced_at`.
    *   Belongs to a `User`.
*   **Channel:**
    *   `name`, `stream_url`, `logo_url`.
    *   `tvg_id`, `tvg_name`, `group_title` (EPG metadata).
    *   Belongs to a `Provider`.

## Development Workflow

### Setup
```bash
# Install dependencies, setup DB, and build assets
mix setup
```

### Running
```bash
# Start the server (accessible at localhost:4000)
mix phx.server

# Start interactive shell
iex -S mix phx.server
```

### Testing
```bash
# Run the test suite
mix test
```

## Conventions
*   **IPTV Integration:** The `Streamix.Iptv.Client` module encapsulates all external HTTP logic. It constructs URLs for standard IPTV panel APIs (Xtream Codes style).
*   **Safety:** Passwords for providers are marked `redact: true` in the Ecto schema.
*   **UI:** Uses standard Phoenix CoreComponents and Tailwind classes.
