# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Streamix is an IPTV streaming application built with Phoenix 1.8 and LiveView. It allows users to manage IPTV providers, sync channels from M3U playlists, and track favorites and watch history.

## Development Commands

```bash
# Initial setup
mix setup

# Run development server
mix phx.server
iex -S mix phx.server  # with IEx shell

# Run tests
mix test
mix test test/path/to/test.exs  # single file
mix test --failed               # rerun failed tests

# Pre-commit check (run before committing)
mix precommit  # compiles with warnings-as-errors, formats, runs tests

# Database operations
mix ecto.gen.migration migration_name_using_underscores
mix ecto.migrate
mix ecto.reset  # drops, creates, migrates, seeds

# Assets
mix assets.build
mix assets.deploy  # for production
```

## Architecture

### Core Contexts

**Streamix.Accounts** (`lib/streamix/accounts.ex`)
- User authentication via magic link (passwordless)
- Uses `current_scope` pattern from Phoenix 1.8 (not `current_user`)
- Scope-based authorization configured in `config/config.exs`

**Streamix.Iptv** (`lib/streamix/iptv.ex`)
- Main context for IPTV functionality
- Manages providers, channels, favorites, and watch history
- Key function: `sync_provider/1` fetches M3U playlist and bulk-inserts channels

### IPTV Subsystem

- `Iptv.Client` - HTTP client using Req for provider API calls
- `Iptv.Parser` - M3U/M3U8 playlist parser extracting channel metadata
- `Iptv.Provider` - User's IPTV service credentials and sync status
- `Iptv.Channel` - Individual channels with stream URLs and metadata
- `Iptv.Favorite` / `Iptv.WatchHistory` - User engagement tracking

### Authentication Flow

Routes are organized by authentication requirement:
- Public routes: `:browser` pipeline only
- Auth-required: `:browser` + `:require_authenticated_user`
- Guest-only: `:browser` + `:redirect_if_user_is_authenticated`

Access user in templates via `@current_scope.user`, never `@current_user`.

## Key Conventions

- Use `Req` for HTTP requests (not HTTPoison, Tesla, or :httpc)
- LiveView templates must wrap content in `<Layouts.app flash={@flash} current_scope={@current_scope}>`
- Use `<.icon name="hero-*">` for icons (heroicons), not Heroicons modules
- Use LiveView streams for collections to prevent memory issues
- Tailwind CSS v4 with `@import "tailwindcss"` syntax in app.css
- Context functions take `user_id` or `scope` as first argument for authorization
