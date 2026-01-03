# Streamix Project Context (AGY Optimized)

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
*   **LiveView:** The interactive UI is built with LiveView.
*   **Router:** Defined in `lib/streamix_web/router.ex`.

## Development Workflow
```bash
mix setup        # Setup dependencies and DB
mix phx.server   # Start server
mix test         # Run test suite
```

# 🚀 Google Antigravity (AGY) System Rules

These rules are optimized for the **Agent Manager (Mission Control)** and **Gemini 3 Pro** orchestration.

## 1. Multi-Agent Orchestration (Mission Control)
- **Parallel Workflows**: Agents should work in parallel when possible (e.g., one agent writing tests while another refactors code).
- **Background Execution**: Long-running tasks (like full sync simulations) should be run via the Agent Manager in the background.

## 2. Visual Artifacts & Verification
- **Browser-in-the-Loop**: Use the AGY browser agent to verify UI changes in LiveView.
- **Verification**: Always take a screenshot/video of the UI after visual changes to provide "Visual Artifacts" for verification.

## 3. Coding Conventions
- **Idiomatic Elixir**: Use pipes `|>`, pattern matching, and function components.
- **Client Safety**: All external calls MUST go through `Streamix.Iptv.Client`.
- **Changesets**: Validate all DB interactions using Ecto Changesets.

## 4. Safety & Redaction
- **Redact Sensitive Info**: Always use `redact: true` for passwords and tokens in schemas.
- **Logs**: Never log raw responses from IPTV providers.

## 5. Agent Behavior
- **Concise Reporting**: Focus on the code and the "why".
- **Verification First**: Run `mix test` and check UI artifacts before declaring a task complete.
