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

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :streamix, StreamixWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "eSiWVZQ3u7juRt6Hhob5sPFAefFczSJ1FOvin5+TeBJZO1Lh/1GWmWD/uYy815D9",
  server: false

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
