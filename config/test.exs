import Config

# Mark environment as test (used to skip provider initialization in Application)
config :streamix, env: :test

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Database connection details are loaded from TEST_DATABASE_URL in config/runtime.exs.
# If TEST_DATABASE_URL is absent, runtime.exs derives a sibling *_test database from
# DATABASE_URL automatically. Remote hosts fail closed unless
# ALLOW_REMOTE_TEST_DATABASE=i-know-this-is-a-test-database is explicitly set.
# The MIX_TEST_PARTITION environment variable can be used for built-in test
# partitioning in CI.
config :streamix, Streamix.Repo,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  # Coverage instrumentation makes concurrent association preloads noticeably
  # slower. Give tasks sharing one sandbox owner time to serialize instead of
  # dropping them after DBConnection's tiny adaptive queue window.
  queue_target: 2_000,
  queue_interval: 5_000,
  timeout: 30_000

# Endpoint runs in server mode so Playwright E2E tests can hit it.
# ConnTest/LiveViewTest don't care — they mock the conn.
config :streamix, StreamixWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "eSiWVZQ3u7juRt6Hhob5sPFAefFczSJ1FOvin5+TeBJZO1Lh/1GWmWD/uYy815D9",
  server: true

# Enables Phoenix.Ecto.SQL.Sandbox plug in endpoint + LiveAcceptance on_mount,
# so Playwright sessions share the per-test sandbox via User-Agent metadata.
config :streamix, :sql_sandbox, true

# Allow session cookie over HTTP (localhost) in test env.
config :streamix, :session_secure, false

# Disable rate limiting in tests to prevent flaky failures on repeated logins.
config :streamix, :disable_rate_limit, true

# L1 entries (e.g. the cached global provider) use fixed keys and ConCache
# is shared across the suite while the DB is per-test sandboxed — bypass
# the local cache so tests never see another test's entries.
config :streamix, :disable_local_cache, true

# Qdrant is optional and must never make the test suite depend on a service
# running on the developer machine or CI runner.
config :streamix, :qdrant, enabled: false

# The provider health sampler runs in its own process and periodically touches
# the database. Disable it in tests so SQL sandbox ownership stays per-test.
config :streamix, :provider_health_monitor_enabled, false

# Tests still exercise the legacy 302-to-source-proxy flow. Pin the
# backend to `:redirect` so `stream_controller_test.exs` keeps asserting
# on the trusted-proxy redirect chain instead of trying to actually pump
# bytes through Finch in unit tests.
config :streamix, :stream_proxy_backend, :redirect

# PhoenixTest + Playwright
#
# The default browser is chromium, but CI matrices flip this across
# chromium/firefox/webkit by exporting PLAYWRIGHT_BROWSER. Any unknown value
# falls back to chromium so a typo doesn't crash the suite.
playwright_browser =
  case System.get_env("PLAYWRIGHT_BROWSER") do
    "firefox" -> :firefox
    "webkit" -> :webkit
    "chromium" -> :chromium
    nil -> :chromium
    _ -> :chromium
  end

playwright_options = [
  browser: playwright_browser,
  headless: System.get_env("PLAYWRIGHT_HEADED") != "true",
  # Keep browser E2E contexts deterministic. Service-worker activation can
  # reload a page while Playwright is evaluating it, destroying the execution
  # context and turning unrelated player assertions into flakes.
  browser_context_opts: [service_workers: "block"],
  js_logger: false,
  trace: System.get_env("PW_TRACE", "false") in ~w(t true),
  screenshot: System.get_env("PW_SCREENSHOT", "false") in ~w(t true)
]

playwright_options =
  case System.get_env("PLAYWRIGHT_WS_ENDPOINT") do
    endpoint when is_binary(endpoint) and endpoint != "" ->
      Keyword.merge(playwright_options, ws_endpoint: endpoint, browser_pool: false)

    _ ->
      playwright_options
  end

config :phoenix_test,
  otp_app: :streamix,
  endpoint: StreamixWeb.Endpoint,
  playwright: playwright_options

# In test we don't send emails
config :streamix, Streamix.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Disable Oban in tests (manual mode prevents auto-execution)
config :streamix, Oban, testing: :manual

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
