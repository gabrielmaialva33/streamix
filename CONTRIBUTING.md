# Contributing to Streamix

Thanks for contributing to Streamix. This repository contains the Phoenix backend and web UI for the platform. The old
in-repo TV app was extracted, so contributions here should target the current Elixir / Phoenix codebase.

## Before You Start

- Read [README.md](README.md) for setup and project scope.
- Read [AGENTS.md](AGENTS.md) for repo-specific implementation rules and conventions.
- Read [docs/phoenix-guidelines.md](docs/phoenix-guidelines.md) for Phoenix / LiveView / Ecto patterns.
- Follow the [Code of Conduct](CODE_OF_CONDUCT.md).

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).

## Development Environment

### Requirements

- Elixir 1.20+
- OTP 29+
- Docker
- Node.js 26+ and npm 12+

### First-Time Setup

```bash
git clone git@github.com:gabrielmaialva33/streamix.git
cd streamix

docker compose up -d
cp .env.example .env

# required before mix setup succeeds
# set ADMIN_PASSWORD and PROVIDER_ENCRYPTION_KEY in .env

cd assets && npm ci && cd ..
mix setup
mix phx.server
```

Notes:

- `mix setup` runs migrations, seeds, and builds assets.
- `priv/repo/seeds.exs` requires `ADMIN_PASSWORD`.
- test DB setup can be omitted from `.env`; `TEST_DATABASE_URL` is inferred from `DATABASE_URL` when missing.
- optional features such as Qdrant, RabbitMQ, GIndex, and global provider sync are configured through `.env`.

## Where to Contribute

Typical contribution areas:

- Phoenix / LiveView UI in `lib/streamix_web/live`
- HTTP / JSON APIs in `lib/streamix_web/controllers/api/v1`
- Domain logic in `lib/streamix/*`
- Database schema and migrations in `priv/repo/migrations`
- Frontend hooks and player logic in `assets/js`
- Documentation in `README*.md`, `AGENTS.md`, `docs/`, `CONTRIBUTING.md`, `SECURITY.md`

If you are adding or changing behavior, update the relevant docs in the same PR.

## Reporting Bugs and Requesting Changes

### Bugs

Open an issue with:

1. A clear title
2. Reproduction steps
3. Expected vs actual behavior
4. Relevant logs, screenshots, or failing requests
5. Environment details:
    - Elixir / OTP version
    - Browser or client type
    - Database and Docker setup
    - Whether optional services such as Redis / Qdrant / RabbitMQ were enabled

### Improvements

Open an issue or PR that explains:

- the problem being solved
- the proposed approach
- why the change fits Streamix instead of living in a downstream deployment

## Branches and Commits

- Base your work on `master`.
- Keep PRs focused on one concern.
- Use short, descriptive branch names such as `feat/admin-billing-copy` or `fix/watch-party-drift`.
- Commit messages should explain the why, not just the what.

Conventional commits are welcome, but clarity matters more than ceremony.

## Coding Conventions

Follow the repo rules in [AGENTS.md](AGENTS.md). The most important ones:

- Use `Req` for HTTP requests.
- Use `@current_scope.user`, never `@current_user`.
- Use LiveView streams for list rendering.
- Do not introduce inline scripts or deprecated Phoenix helpers.
- Keep one module per file.
- Do not use `String.to_atom/1` on user input.
- Do not log plaintext provider credentials or raw upstream responses.
- Keep GIndex flows sequential where the current code expects low concurrency.

## Testing and Verification

Run the smallest relevant command first during development, then the full gate before opening a PR.

```bash
mix test
mix test path/to/test.exs
mix test path/to/test.exs:42
mix credo --strict
mix quality
mix precommit
```

Expectations:

- add or update tests for behavior changes
- keep compiler warnings at zero
- run `mix precommit` before asking for review
- if you touch JS hooks or player code, run `cd assets && npm ci` first if dependencies are missing

## Database and Migrations

- Use `mix ecto.gen.migration name_in_snake_case` for normal schema changes.
- Preserve TimescaleDB-specific behavior when editing hypertables, compression, retention, or continuous aggregates.
- When the user explicitly directs a baseline rewrite for disposable environments, follow that instruction and update
  docs/tests together.

## Pull Requests

A good PR should include:

- a clear problem statement
- the implementation summary
- verification commands that were actually run
- doc updates if behavior, setup, or public APIs changed

Before opening the PR:

```bash
mix precommit
```

Never commit:

- `.env` files
- secrets or API tokens
- plaintext IPTV credentials
- generated local artifacts that are already ignored

## Security Issues

Do not open a public issue for a suspected vulnerability. Follow [SECURITY.md](SECURITY.md) instead.
