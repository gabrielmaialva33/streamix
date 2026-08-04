# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Player decoders are fetched on demand and are immutable. Include WASM in
# Phoenix's digested static compressors so the first playback transfers the
# compressed artifact instead of hundreds of raw kilobytes per codec.
config :phoenix,
  gzippable_exts: ~w(.js .map .css .txt .text .html .json .svg .eot .ttf .wasm)

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

# Public TV app release metadata shown on /tv. Bumps every TV-app release
# and would otherwise live as 8 module attributes in tv_live.ex — pulling
# them up here means the app-shell module doesn't change when only the
# download URL/checksum changes.
config :streamix, :tv_app,
  release_tag: "v1.0.000",
  release_url: "https://github.com/gabrielmaialva33/streamix-tv/releases/tag/v1.0.000",
  apk_short_url: "https://streamix.mahina.cloud/tv/apk",
  apk_size_mb: "7.3",
  apk_sha256: "5b3f503c8c7ffc4eb99905defa2093d3f412482aaaf25026216143270a75f1cd",
  wgt_short_url: "https://streamix.mahina.cloud/tv/wgt",
  wgt_size_mb: "3.1",
  wgt_sha256: "bbdc5e9592b5b1a17c6783fa80e3176c61ef22f977c8ba7860f032afe11dd83d"

config :streamix,
  ecto_repos: [Streamix.Repo],
  generators: [timestamp_type: :utc_datetime],
  # Default stream-proxy backend. `:beam` pumps bytes through this
  # release via Finch + send_chunked; `:redirect` keeps the legacy
  # 302-to-source-proxy flow. Override at runtime via the
  # `STREAM_PROXY_BACKEND` env var.
  stream_proxy_backend: :beam,
  live_multiplexer_enabled: true,
  live_mux_idle_timeout_ms: 2_000,
  live_mux_stream_idle_timeout_ms: 45_000,
  player_lifecycle_logs: false,
  # Regex patterns matched against the *final* URL after the redirect
  # chain resolves. A hit is treated as an upstream failure even when
  # the response is technically 200/302, so VodProxy rotates to the
  # next alternate URL in `Provider.url_chain/1`. Default: tuliprox-style
  # "service abuse" / suspended-account landing pages.
  failover_redirect_patterns: [~r/service[-_]abuse/iE, ~r/account[-_]suspended/iE],
  # Dedicated Finch pool for long-lived BEAM-side stream proxy requests.
  # Keep this separate from Streamix.Finch so VOD/Live sockets cannot
  # starve catalog sync, image, metadata, and provider-health calls.
  stream_finch_pools: %{
    :default => [
      size: 25,
      count: 4,
      # Finch currently documents HTTP/2 response streaming as having no
      # backpressure mechanism, which is a poor fit for large media bodies.
      protocols: [:http1],
      conn_max_idle_time: :timer.seconds(10),
      pool_max_idle_time: :timer.minutes(5)
    ]
  }

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
  version: "0.28.1",
  streamix: [
    args:
      ~w(js/app.js --bundle --splitting --format=esm --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
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
  metadata: [
    :request_id,
    :user_id,
    :context,
    :reason,
    :error,
    :exception,
    :movie_name,
    :response_keys,
    :player_stage,
    :player_session_id,
    :player_engine,
    :stream_type,
    :content_type,
    :source_type,
    :using_avplayer,
    :native_touch_controls,
    :native_current_time,
    :native_duration,
    :native_ready_state,
    :native_network_state,
    :native_paused,
    :native_seeking,
    :native_autoplay,
    :native_preload,
    :native_buffered_range_count,
    :native_buffered_ranges,
    :native_has_current_src,
    :native_resume_time,
    :native_has_audio_issue,
    :native_error_name,
    :native_error_message,
    :api_error_code,
    :reason_kind
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Gettext configuration - Portuguese Brazil as default
config :gettext, :default_locale, "pt_BR"
config :streamix, StreamixWeb.Gettext, default_locale: "pt_BR"

# Oban - Background jobs
config :streamix, Oban,
  repo: Streamix.Repo,
  # In-memory leader election. The Database peer in Oban 2.22 has a
  # quiet failure mode in single-node prod: if the bootstrap upsert
  # races with a stale row, the peer registers but never wins the
  # leader bit, and Cron stays silent forever. Global is dead-simple
  # for a single node — the only erlang node always elects itself —
  # and works equally well across a libcluster mesh when we get there.
  peer: Oban.Peers.Global,
  queues: [
    default: 10,
    sync: 3,
    billing: 1,
    series_details: 2,
    ai: 1,
    # GIndex ingestion: a small dispatcher queue that just enqueues work.
    # EndpointManager keeps an ordered two-Worker pool for whole-listing
    # failover; it does not split one paginated walk across both hosts.
    gindex_dispatch: 1,
    # Concurrency 1: parallel scan roots previously tipped the shared
    # third-party Workers into cascading 500/503 responses. Serializing
    # roots costs nothing on wall-clock because the 1 q/s Pacer is the
    # actual bottleneck, and it prevents independent walks competing for
    # opaque upstream capacity.
    gindex_scan: 1,
    # TMDB enrichment for gindex rows. Concurrency of 3 matches the
    # pool of 3 tokens (round-robin) so each worker runs on its own
    # bucket and nobody blocks each other on 429s.
    gindex_enrich: 3,
    # Torrent ingestion. Concurrency 2 keeps two sources walking in
    # parallel without overwhelming any single upstream — each source
    # paces itself per `Streamix.Iptv.Torrent.Source.rate_limit_ms/0`.
    torrent_sync: 2
  ],
  plugins: [
    Oban.Plugins.Pruner,
    # Lifeline is the last-resort guard for a genuinely wedged node. Keep
    # this above the longest legitimate worker timeout (GIndex/AI/torrent
    # are capped at 2h30) so a live job is never made available a second
    # time. Single-node deploy restarts are recovered immediately by
    # Streamix.ObanStartupRecovery instead of waiting for this threshold.
    {Oban.Plugins.Lifeline, rescue_after: :timer.hours(3)},
    # Keeps the partial indexes on oban_jobs healthy — noticeable on a
    # queue that churns thousands of jobs per week like gindex_scan.
    {Oban.Plugins.Reindexer, schedule: "@weekly"},
    {Oban.Plugins.Cron,
     crontab: [
       # Cleanup orphaned favorites/history daily at 2 AM
       {"0 2 * * *", Streamix.Workers.CleanupOrphanedDataWorker},
       # Retain detailed client QoE samples for 90 days.
       {"30 2 * * *", Streamix.Workers.CleanupQoeEventsWorker},
       # Sync all providers every 6 hours
       {"0 */6 * * *", Streamix.Workers.SyncAllProvidersWorker},
       # Sync global provider every 4 hours, offset from the all-providers burst
       {"10 */4 * * *", Streamix.Workers.SyncGlobalProviderWorker},
       # Sync GIndex providers daily at 3 AM
       {"0 3 * * *", Streamix.Workers.SyncGindexProviderWorker},
       # TMDB lookup for freshly-ingested gindex rows (poster + tmdb_id).
       # 30min after the sync gives the orchestrator time to finalize.
       # The orchestrator also auto-triggers this worker on
       # sync_status=completed; this cron is the safety net for runs
       # that ended in "failed" or when the auto-trigger didn't fire.
       {"30 3 * * *", Streamix.Workers.Gindex.BackfillTmdbWorker},
       # Sync torrent provider sources daily at 4 AM
       {"0 4 * * *", Streamix.Workers.SyncTorrentProviderWorker},
       # Index embeddings for semantic search daily at 5 AM
       {"0 5 * * *", Streamix.Workers.IndexEmbeddingsWorker},
       # Repair missing Qdrant collections after each application boot without
       # making Phoenix startup depend on the optional vector database.
       {"@reboot", Streamix.Workers.EnsureAiCollectionsWorker},
       # Backfill TMDB backdrop/image assets daily at 4 AM
       {"0 4 * * *", Streamix.Workers.BackfillTmdbAssetsWorker},
       # Reconcile providers stuck in `sync_status="syncing"` whose
       # owning Oban jobs no longer exist (container restarts mid-run,
       # cancelled jobs, etc). Every 10 minutes is cheap — a single
       # indexed query per check.
       {"*/10 * * * *", Streamix.Workers.SyncWatchdogWorker},
       # Reconcile Stripe subscriptions daily so missed/out-of-order
       # webhooks do not leave local access stale.
       {"30 1 * * *", Streamix.Workers.ReconcileStripeSubscriptionsWorker}
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

# RabbitMQ configuration (Broadway)
config :streamix, :rabbitmq,
  enabled: false,
  connection: [
    host: "localhost",
    port: 5672,
    username: "guest",
    password: "guest",
    virtual_host: "/"
  ],
  # Broadway pipeline settings
  # IMPORTANT: Keep concurrency at 1 for GIndex to avoid rate limiting
  broadway: [
    processor_concurrency: 1,
    batcher_concurrency: 1,
    batch_size: 10,
    batch_timeout: 2_000
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
