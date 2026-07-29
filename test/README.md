# Test Organization

Streamix follows the standard Phoenix and ExUnit layout: tests live under `test/`, shared case templates and fixtures
live under `test/support/`, and test paths mirror the application namespace under `lib/`.

## Directory Map

- `test/streamix/` covers domain contexts, schemas, workers, pure services, and data-layer behavior.
- `test/streamix_web/` covers controllers, plugs, LiveViews, web helpers, route behavior, and web-facing contracts.
- `test/streamix_web/e2e/` covers Playwright-backed browser checks and must use the `:playwright` tag.
- `test/support/` contains case templates, fixtures, stubs, and test-only support modules compiled only in `:test`.

## Case Templates

- Use `Streamix.DataCase` for context, schema, repository, worker, and data-layer tests.
- Use `StreamixWeb.ConnCase` for controllers, plugs that need a `%Plug.Conn{}`, route tests, and LiveView tests.
- Use `ExUnit.Case` for pure modules that do not need the Repo, endpoint, connection helpers, or LiveView helpers.
- Keep `async: true` unless the test mutates global application config, uses named processes, talks to external services,
  depends on shared caches, or uses Playwright.

## Naming

- Mirror the module path when there is a direct module target:
  `lib/streamix/iptv/gindex/parser.ex` -> `test/streamix/iptv/gindex/parser_test.exs`.
- Context entrypoint tests can stay at the context root:
  `lib/streamix/accounts.ex` -> `test/streamix/accounts_test.exs`.
- Group focused slices under the context when the root context test becomes too broad:
  `test/streamix/accounts/admin_test.exs`, `test/streamix/billing/admin_test.exs`.
- Use `describe "function/arity"` for public APIs and `describe "route or surface"` for web behavior.

## Tags

Default `mix test` excludes `:integration`, `:slow`, and `:playwright`.

- `@tag :integration` for tests that require real providers, external services, or long worker flows.
- `@tag :slow` for deterministic tests that are local but intentionally slow.
- `@moduletag :playwright` for browser tests under `test/streamix_web/e2e/`.

Run opt-in suites explicitly:

```bash
mix test --cover
mix test --include integration
mix test --include slow
mix test --include playwright test/streamix_web/e2e
```

`mix test --cover` enforces the current 45% project-wide ratchet. Raise the
threshold as coverage improves; do not lower it or add broad module exclusions
to make a regression pass.

CI runs the default suite with coverage, the deterministic `:slow` tests, and
the four self-contained WebKit journeys. The `:integration` tag remains manual
because those cases require live providers or external torrent services.

On Arch Linux, run the WebKit-focused browser suite through the pinned
Playwright Ubuntu container instead of installing compatibility libraries:

```bash
scripts/test-webkit-docker.sh
```

Pass one or more test paths to narrow the run:

```bash
scripts/test-webkit-docker.sh test/streamix_web/e2e/player_lifecycle_test.exs
```

## Assertions

- Prefer stable DOM ids, data attributes, and `has_element?/2` / `element/3` in LiveView tests.
- Prefer fixture helpers from `test/support/fixtures/` over ad hoc records when the setup is reusable.
- Prefer `start_supervised!/1`, monitors, or message assertions over fixed sleeps.
- Keep comments only where they document a client contract, regression reason, or non-obvious setup boundary.
