import Config

# Mark environment as test (used to skip provider initialization in Application)
config :streamix, env: :test

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Database connection details are loaded from TEST_DATABASE_URL in config/runtime.exs.
# If TEST_DATABASE_URL is absent, runtime.exs derives a sibling *_test database from
# DATABASE_URL automatically. The MIX_TEST_PARTITION environment variable can be used
# for built-in test partitioning in CI.
config :streamix, Streamix.Repo,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

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

# PhoenixTest + Playwright
config :phoenix_test,
  otp_app: :streamix,
  endpoint: StreamixWeb.Endpoint,
  playwright: [
    browser: :chromium,
    headless: System.get_env("PLAYWRIGHT_HEADED") != "true",
    js_logger: false,
    trace: System.get_env("PW_TRACE", "false") in ~w(t true),
    screenshot: System.get_env("PW_SCREENSHOT", "false") in ~w(t true),
    # Give LiveView channels time to drain before dropping the sandbox owner,
    # avoiding DBConnection.ConnectionError flakiness at test teardown.
    ecto_sandbox_stop_owner_delay: 200
  ]

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
