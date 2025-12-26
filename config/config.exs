# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :streamix, :scopes,
  user: [
    default: true,
    module: Streamix.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Streamix.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :streamix,
  ecto_repos: [Streamix.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :streamix, StreamixWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: StreamixWeb.ErrorHTML, json: StreamixWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Streamix.PubSub,
  live_view: [signing_salt: "Jhh/r6Do"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :streamix, Streamix.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  streamix: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  streamix: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Gettext configuration - Portuguese Brazil as default
config :gettext, :default_locale, "pt_BR"
config :streamix, StreamixWeb.Gettext, default_locale: "pt_BR"

# Oban - Background jobs
config :streamix, Oban,
  repo: Streamix.Repo,
  queues: [default: 10, sync: 3, series_details: 2],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       # Sync all providers every 6 hours
       {"0 */6 * * *", Streamix.Workers.SyncAllProvidersWorker},
       # Sync global provider every 4 hours
       {"0 */4 * * *", Streamix.Workers.SyncGlobalProviderWorker}
     ]}
  ]

# IPTV configuration
config :streamix, Streamix.Iptv,
  # Sync configuration
  sync_batch_size: 500,
  sync_timeout: :timer.minutes(10),
  # HTTP client timeouts
  http_timeout: :timer.seconds(60),
  http_info_timeout: :timer.seconds(10),
  # Cache TTL in seconds
  cache_ttl: 3600,
  # Default pagination
  default_page_size: 100,
  max_page_size: 500

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
