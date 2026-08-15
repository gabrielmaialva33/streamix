import Config
import Dotenvy

alias Streamix.RuntimeConfig

# Load .env file in dev/test environments
# This creates an env map that merges .env with System.get_env()
env =
  if config_env() in [:dev, :test] do
    source!([".env", System.get_env()])
  else
    System.get_env()
  end

# Helper to get env value
get_env = fn key ->
  case env do
    %{^key => value} when is_binary(value) and value != "" -> value
    _ -> System.get_env(key)
  end
end

infer_test_database_url = fn
  nil ->
    nil

  database_url ->
    uri = URI.parse(database_url)

    case uri.path do
      "/" <> database_name when database_name != "" ->
        test_database_name =
          cond do
            String.ends_with?(database_name, "_test") ->
              database_name

            String.ends_with?(database_name, "_dev") ->
              String.replace_suffix(database_name, "_dev", "_test")

            true ->
              database_name <> "_test"
          end

        %{uri | path: "/" <> test_database_name}
        |> URI.to_string()

      _ ->
        database_url
    end
end

# Database URL (works in all environments, loaded from .env in dev/test)
# Example: ecto://user:pass@host/database
database_url =
  case config_env() do
    :test ->
      database_url =
        get_env.("TEST_DATABASE_URL") || infer_test_database_url.(get_env.("DATABASE_URL"))

      allowed_hosts =
        get_env.("TEST_DATABASE_ALLOWED_HOSTS")
        |> RuntimeConfig.csv()
        |> Enum.map(&String.downcase/1)

      Streamix.RuntimeDatabaseSafety.validate_test_url!(database_url,
        allow_remote?:
          get_env.("ALLOW_REMOTE_TEST_DATABASE") ==
            Streamix.RuntimeDatabaseSafety.remote_override(),
        allowed_hosts: allowed_hosts
      )

    _ ->
      get_env.("DATABASE_URL")
  end ||
    raise """
    environment variable #{if config_env() == :test, do: "TEST_DATABASE_URL/DATABASE_URL", else: "DATABASE_URL"} is missing.
    For example: ecto://USER:PASS@HOST/DATABASE
    """

maybe_ipv6 =
  if RuntimeConfig.boolean!("ECTO_IPV6", get_env.("ECTO_IPV6"), false),
    do: [:inet6],
    else: []

repo_pool_size =
  case config_env() do
    :test ->
      RuntimeConfig.integer!(
        "TEST_POOL_SIZE",
        get_env.("TEST_POOL_SIZE"),
        System.schedulers_online() * 2,
        min: 1
      )

    _ ->
      RuntimeConfig.integer!("POOL_SIZE", get_env.("POOL_SIZE"), 10, min: 1)
  end

config :streamix, Streamix.Repo,
  url: database_url,
  pool_size: repo_pool_size,
  migration_lock: :pg_advisory_lock,
  socket_options: maybe_ipv6

# Redis URL (loaded from .env in dev/test via Dotenvy, System env in prod)
redis_url =
  case config_env() do
    :test ->
      explicit_test_url = get_env.("TEST_REDIS_URL")
      source_url = explicit_test_url || get_env.("REDIS_URL") || "redis://localhost:6379"

      allowed_hosts =
        get_env.("TEST_REDIS_ALLOWED_HOSTS")
        |> RuntimeConfig.csv()
        |> Enum.map(&String.downcase/1)

      Streamix.RuntimeRedisSafety.prepare_test_url!(source_url,
        explicit?: is_binary(explicit_test_url),
        allow_remote?:
          get_env.("ALLOW_REMOTE_TEST_REDIS") ==
            Streamix.RuntimeRedisSafety.remote_override(),
        allowed_hosts: allowed_hosts
      )

    _ ->
      get_env.("REDIS_URL") || "redis://localhost:6379"
  end

config :streamix, :redis_url, redis_url

# Provider password encryption key (AES-256-GCM)
# Generate with: mix phx.gen.secret 32
config :streamix, :provider_encryption_key, get_env.("PROVIDER_ENCRYPTION_KEY")

# Stripe billing configuration.
#
# Self-service checkout is enabled when STRIPE_SECRET_KEY is present. Webhooks
# require STRIPE_WEBHOOK_SECRET and should point to /api/billing/webhooks/stripe.
config :streamix, :stripe,
  secret_key: get_env.("STRIPE_SECRET_KEY"),
  webhook_secret: get_env.("STRIPE_WEBHOOK_SECRET")

# Global provider configuration (optional)
# Set GLOBAL_PROVIDER_ENABLED=true to enable
if RuntimeConfig.boolean!(
     "GLOBAL_PROVIDER_ENABLED",
     get_env.("GLOBAL_PROVIDER_ENABLED"),
     false
   ) do
  config :streamix, :global_provider,
    enabled: true,
    name: get_env.("GLOBAL_PROVIDER_NAME") || "Streamix Global",
    url: get_env.("GLOBAL_PROVIDER_URL"),
    username: get_env.("GLOBAL_PROVIDER_USERNAME"),
    password: get_env.("GLOBAL_PROVIDER_PASSWORD")
else
  config :streamix, :global_provider, enabled: false
end

# TMDB API configuration (optional, for enriched movie metadata).
#
# The default profile (`:streamix, :tmdb`) is used for Xtream ingestion.
# The `:gindex` profile can override the api_token to isolate its quota.
# `GINDEX_TMDB_API_TOKEN` feeds that profile.
if tmdb_token = get_env.("TMDB_API_TOKEN") do
  config :streamix, :tmdb,
    enabled: true,
    api_token: tmdb_token
else
  config :streamix, :tmdb, enabled: false
end

# Pool of TMDB tokens for the `:gindex` profile. Round-robin rotation
# (see `Streamix.Iptv.TmdbTokenPool`) triples effective throughput and
# gives retries a different bucket to fall back to when one token hits
# TMDB's per-token rate ceiling. `api_token` is kept as the first element
# so callers that read the flat field (e.g. `enabled?/1`) still work.
gindex_tmdb_tokens =
  ["GINDEX_TMDB_API_TOKEN", "GINDEX_TMDB_API_TOKEN_2", "GINDEX_TMDB_API_TOKEN_3"]
  |> Enum.map(get_env)
  |> Enum.filter(&(is_binary(&1) and &1 != ""))

if gindex_tmdb_tokens != [] do
  config :streamix, :tmdb_gindex,
    enabled: true,
    api_token: List.first(gindex_tmdb_tokens),
    api_tokens: gindex_tmdb_tokens
end

# Image resize proxy — cache dir is a volume on the VPS so restarts
# don't throw away the already-encoded thumbnails.
config :streamix, StreamixWeb.Api.V1.ImageResizeController,
  cache_dir: get_env.("IMAGE_CACHE_DIR") || "/app/data/image_cache"

# GIndex daily safety budget. Background ingestion stops before the hard limit
# so interactive download-link resolution retains guaranteed capacity.
gindex_daily_limit =
  RuntimeConfig.integer!("GINDEX_DAILY_LIMIT", get_env.("GINDEX_DAILY_LIMIT"), 8_000, min: 1)

gindex_playback_reserve =
  RuntimeConfig.integer!(
    "GINDEX_PLAYBACK_RESERVE",
    get_env.("GINDEX_PLAYBACK_RESERVE"),
    1_000,
    min: 0
  )

if gindex_playback_reserve >= gindex_daily_limit do
  raise ArgumentError, "GINDEX_PLAYBACK_RESERVE must be lower than GINDEX_DAILY_LIMIT"
end

config :streamix, Streamix.Gindex.QuotaGuard,
  daily_limit: gindex_daily_limit,
  playback_reserve: gindex_playback_reserve

# GIndex pacer budgets (requests-per-second). Tunable from the env
# without a code change — useful when upstream capacity changes.
config :streamix, Streamix.Gindex.Pacer,
  # The third-party Workers expose neither account usage nor reserved
  # capacity to us. Production probing found 1 q/s stable while higher
  # rates caused cascading 500/503 responses. Override GINDEX_GDRIVE_RPS
  # only when the upstream capacity is known.
  gdrive: RuntimeConfig.integer!("GINDEX_GDRIVE_RPS", get_env.("GINDEX_GDRIVE_RPS"), 1, min: 1),
  tmdb_gindex: RuntimeConfig.integer!("GINDEX_TMDB_RPS", get_env.("GINDEX_TMDB_RPS"), 10, min: 1),
  anilist:
    RuntimeConfig.integer!("GINDEX_ANILIST_RPS", get_env.("GINDEX_ANILIST_RPS"), 1, min: 1),
  tomato: RuntimeConfig.integer!("GINDEX_TOMATO_RPS", get_env.("GINDEX_TOMATO_RPS"), 2, min: 1)

config :streamix, Streamix.Gindex.Pagination,
  delay_ms:
    RuntimeConfig.integer!(
      "GINDEX_PAGE_DELAY_MS",
      get_env.("GINDEX_PAGE_DELAY_MS"),
      5_000,
      min: 0
    ),
  jitter_ms:
    RuntimeConfig.integer!(
      "GINDEX_PAGE_JITTER_MS",
      get_env.("GINDEX_PAGE_JITTER_MS"),
      1_000,
      min: 0
    )

# TomatoAnimes API — bearer token provides access to search + metadata
# endpoints (https://edge.betomato.com/v2). Disabled when the env var
# is absent; enabled automatically when set.
if tomato_token = get_env.("TOMATO_BEARER_TOKEN") do
  config :streamix, :tomato,
    enabled: true,
    bearer_token: tomato_token,
    base_url: get_env.("TOMATO_BASE_URL") || "https://edge.betomato.com"
else
  config :streamix, :tomato, enabled: false
end

# GIndex provider configuration (Google Drive Index for movies/series/animes).
# Paths are configured via gindex_drives on the provider record.
if RuntimeConfig.boolean!("GINDEX_ENABLED", get_env.("GINDEX_ENABLED"), false) do
  validate_gindex_url = fn url ->
    url = String.trim(url)
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      String.trim_trailing(url, "/")
    else
      raise ArgumentError, "invalid GIndex endpoint URL; expected an http(s) URL with a host"
    end
  end

  endpoints =
    case get_env.("GINDEX_ENDPOINTS") do
      value when is_binary(value) ->
        value
        |> RuntimeConfig.csv()
        |> Enum.map(validate_gindex_url)

      _ ->
        []
    end

  configured_url =
    case get_env.("GINDEX_URL") do
      url when is_binary(url) -> validate_gindex_url.(url)
      _ -> nil
    end

  sync_url =
    case get_env.("GINDEX_SYNC_URL") do
      url when is_binary(url) -> validate_gindex_url.(url)
      _ -> List.first(endpoints) || configured_url
    end

  stream_url =
    case get_env.("GINDEX_STREAM_URL") do
      url when is_binary(url) -> validate_gindex_url.(url)
      _ -> configured_url
    end

  put_if_present = fn
    config, _key, nil -> config
    config, key, value -> Keyword.put(config, key, value)
  end

  gindex_config =
    [enabled: true]
    |> put_if_present.(:url, sync_url)
    |> put_if_present.(:sync_url, sync_url)
    |> put_if_present.(:stream_url, stream_url)
    |> put_if_present.(:endpoints, if(endpoints == [], do: nil, else: endpoints))

  config :streamix, :gindex_provider, gindex_config
else
  config :streamix, :gindex_provider, enabled: false
end

# Torrent aggregator provider. Off by default — it requires an rqbit
# sidecar to be reachable and brings its own resource/legal footprint,
# so opt-in. RQBIT_URL points at the sidecar's HTTP API. Always off in
# test: the suite boots its own Registry/stub processes and would
# collide with the application-supervised ones.
if config_env() != :test and
     RuntimeConfig.boolean!("TORRENT_ENABLED", get_env.("TORRENT_ENABLED"), false) do
  config :streamix, :torrent_provider,
    enabled: true,
    rqbit_url: get_env.("RQBIT_URL") || "http://rqbit:3030",
    # Shared secret sent as `X-Internal-Auth` on every rqbit call. rqbit
    # has no auth of its own, so when it is reachable over a public
    # hostname an edge/WAF rule must reject requests missing this header.
    rqbit_auth_secret: get_env.("RQBIT_AUTH_SECRET")

  config :streamix, :torrent_source_endpoints,
    eztv: get_env.("EZTV_SOURCE_URL"),
    gratistorrent: get_env.("GRATISTORRENT_SOURCE_URL"),
    comandotorrent: get_env.("COMANDOTORRENT_SOURCE_URL")

  # Native HTML scrapers for BR torrent sites (dubbed/dual movies). Set a
  # site's `*_BASE_URL` to enable; selectors fall back to the common
  # WordPress shape and can be tuned per site if the layout differs.
  config :streamix, :torrent_scrapers,
    comandotorrent: [
      base_url: get_env.("COMANDOTORRENT_BASE_URL"),
      list_path: get_env.("COMANDOTORRENT_LIST_PATH") || "/",
      post_link_selector:
        get_env.("COMANDOTORRENT_POST_SELECTOR") || "article h2 a, .title a, h2.entry-title a"
    ],
    gratistorrent: [
      base_url: get_env.("GRATISTORRENT_BASE_URL"),
      list_path: get_env.("GRATISTORRENT_LIST_PATH") || "/",
      post_link_selector:
        get_env.("GRATISTORRENT_POST_SELECTOR") || "article h2 a, .title a, h2.entry-title a"
    ]
else
  config :streamix, :torrent_provider, enabled: false
end

# External subtitles. Providers are tried in chain order; each is only
# used when its API key is present, so a missing key degrades to "no
# subtitle" instead of erroring. Both keys are free with signup.
config :streamix, :open_subtitles,
  api_key: get_env.("OPENSUBTITLES_API_KEY"),
  user_agent: get_env.("OPENSUBTITLES_USER_AGENT") || "Streamix v1"

config :streamix, :subdl, api_key: get_env.("SUBDL_API_KEY")

# AI Embeddings configuration for semantic search
# Set EMBEDDING_PROVIDER to choose: "gemini" (default) or "nvidia"
# Both can be configured for automatic fallback
config :streamix, :embeddings, provider: get_env.("EMBEDDING_PROVIDER") || "gemini"

# Production currently runs a single BEAM node. Any Oban job left in
# `executing` before that node starts is therefore an orphan from the previous
# container and can be made available immediately. Disable this before adding
# a second worker node.
config :streamix,
       :recover_orphaned_jobs_on_startup,
       config_env() == :prod and
         RuntimeConfig.boolean!(
           "OBAN_RECOVER_ORPHANED_ON_STARTUP",
           get_env.("OBAN_RECOVER_ORPHANED_ON_STARTUP"),
           true
         )

# Gemini AI configuration for embeddings (3072 dimensions)
if gemini_api_key = get_env.("GEMINI_API_KEY") do
  config :streamix, :gemini, api_key: gemini_api_key
end

# NVIDIA NIM configuration for embeddings (1024 dimensions).
# 2026-06: NVIDIA moved the embedding API to the OpenAI-compatible
# `integrate.api.nvidia.com/v1` surface, which requires the new
# namespaced model id `nvidia/nv-embedqa-e5-v5` (the old short form
# returns 404 "page not found"). Override via NVIDIA_EMBEDDING_MODEL
# if a different model is needed.
if nvidia_api_key = get_env.("NVIDIA_API_KEY") do
  config :streamix, :nvidia,
    api_key: nvidia_api_key,
    embedding_model: get_env.("NVIDIA_EMBEDDING_MODEL") || "nvidia/nv-embedqa-e5-v5"
end

# Qdrant vector database configuration
# Required for semantic search functionality
config :streamix, :qdrant,
  enabled:
    config_env() != :test and
      RuntimeConfig.boolean!("QDRANT_ENABLED", get_env.("QDRANT_ENABLED"), true),
  url: get_env.("QDRANT_URL") || "http://localhost:6333",
  api_key: get_env.("QDRANT_API_KEY")

# RabbitMQ configuration for Broadway distributed workers
# Set RABBITMQ_ENABLED=true to enable
if RuntimeConfig.boolean!("RABBITMQ_ENABLED", get_env.("RABBITMQ_ENABLED"), false) do
  config :streamix, :rabbitmq,
    enabled: true,
    connection: [
      host: get_env.("RABBITMQ_HOST") || "localhost",
      port:
        RuntimeConfig.integer!("RABBITMQ_PORT", get_env.("RABBITMQ_PORT"), 5_672,
          min: 1,
          max: 65_535
        ),
      username: get_env.("RABBITMQ_USERNAME") || "guest",
      password: get_env.("RABBITMQ_PASSWORD") || "guest",
      virtual_host: get_env.("RABBITMQ_VHOST") || "/"
    ],
    broadway: [
      # Keep at 1 to avoid GIndex rate limiting (tasks run sequentially)
      processor_concurrency:
        RuntimeConfig.integer!(
          "BROADWAY_CONCURRENCY",
          get_env.("BROADWAY_CONCURRENCY"),
          1,
          min: 1
        ),
      batcher_concurrency: 1,
      batch_size: 10,
      batch_timeout: 2_000
    ]
end

# Proxy URLs for CDN / reverse proxy domains
# These proxies handle mixed content, image caching, and stream delivery
# `:stream_proxy_urls` is the *pool* the StreamController.pick_source_proxy/2
# samples from on every redirect. Each entry is a fully-qualified base URL
# (no trailing slash) of a source nginx that knows how to proxy_pass to
# the IPTV upstream. Different sources should sit behind different ASNs so
# that a vauth IP banned for one source still works through the other.
#
# Comma-separated env: `STREAM_PROXY_URLS=https://source.mahina.cloud,https://source2.mahina.cloud`
# Falls back to the single `STREAM_PROXY_URL` for older deploys.
stream_proxy_urls =
  get_env.("STREAM_PROXY_URLS")
  |> RuntimeConfig.csv()

case get_env.("STREAM_PROXY_BACKEND") do
  "redirect" -> config :streamix, :stream_proxy_backend, :redirect
  "beam" -> config :streamix, :stream_proxy_backend, :beam
  _ -> :ok
end

config :streamix,
  iptv_upstream_user_agent: get_env.("IPTV_UPSTREAM_USER_AGENT") || "IPTVSmartersPlayer",
  live_multiplexer_enabled:
    RuntimeConfig.boolean!("LIVE_MULTIPLEXER_ENABLED", get_env.("LIVE_MULTIPLEXER_ENABLED"), true),
  live_mux_idle_timeout_ms:
    RuntimeConfig.integer!(
      "LIVE_MUX_IDLE_TIMEOUT_MS",
      get_env.("LIVE_MUX_IDLE_TIMEOUT_MS"),
      2_000,
      min: 0,
      max: 60_000
    ),
  live_mux_stream_idle_timeout_ms:
    RuntimeConfig.integer!(
      "LIVE_MUX_STREAM_IDLE_TIMEOUT_MS",
      get_env.("LIVE_MUX_STREAM_IDLE_TIMEOUT_MS"),
      45_000,
      min: 5_000,
      max: 300_000
    ),
  vod_multiplexer_enabled:
    RuntimeConfig.boolean!("VOD_MULTIPLEXER_ENABLED", get_env.("VOD_MULTIPLEXER_ENABLED"), false),
  vod_block_size_bytes:
    RuntimeConfig.integer!(
      "VOD_BLOCK_SIZE_BYTES",
      get_env.("VOD_BLOCK_SIZE_BYTES"),
      4 * 1_024 * 1_024,
      min: 256 * 1_024,
      max: 64 * 1_024 * 1_024
    ),
  vod_cache_dir: get_env.("VOD_CACHE_DIR"),
  vod_cache_max_bytes:
    RuntimeConfig.integer!(
      "VOD_CACHE_MAX_BYTES",
      get_env.("VOD_CACHE_MAX_BYTES"),
      20 * 1_024 * 1_024 * 1_024,
      min: 256 * 1_024 * 1_024
    ),
  stream_proxy_url: get_env.("STREAM_PROXY_URL") || "https://source.mahina.cloud",
  stream_proxy_urls: stream_proxy_urls,
  tmdb_proxy_url: get_env.("TMDB_PROXY_URL") || "https://tmdb.mahina.cloud",
  imgmxa_proxy_url: get_env.("IMGMXA_PROXY_URL") || "https://imgmxa.mahina.cloud",
  image_proxy_url: get_env.("IMAGE_PROXY_URL") || "https://img.mahina.cloud",
  # Public hostname of the GIndex direct-stream nginx proxy. Catalog
  # URLs for GIndex content point straight at it instead of
  # `/api/stream/proxy`, so 4K MKV bytes never traverse the BEAM and
  # we sidestep Cloudflare's 524 origin timeout. Falsy disables the
  # direct route and keeps the legacy proxy flow.
  gindex_direct_proxy_url: get_env.("GINDEX_DIRECT_PROXY_URL"),
  # Shared secret presented by the gindex nginx to the resolve-only
  # endpoint via `X-Internal-Auth`. Required for the direct route to
  # function — when unset the controller responds with 401 and the
  # nginx Lua falls back through its error handler.
  gindex_resolve_secret: get_env.("GINDEX_RESOLVE_SECRET"),
  # Opt the browser into the avbridge engine for GIndex MKV/HEVC.
  # Preferred path: lighter bundle, MIT, does not need
  # SharedArrayBuffer. The hook falls back to AVPlayer if init
  # fails (e.g. the runtime cannot decode HEVC via WebCodecs).
  feature_avbridge:
    RuntimeConfig.boolean!("FEATURE_AVBRIDGE", get_env.("FEATURE_AVBRIDGE"), false),
  # Opt the browser into the h265web.js engine for GIndex MKV/HEVC
  # content. Alternate GPU path; needs SAB + COOP+COEP headers to
  # actually run multi-threaded decode (without them the SDK boots
  # but the AudioContext/decoder pipeline never starts). Off by
  # default; flip when the headers are wired.
  feature_h265web: RuntimeConfig.boolean!("FEATURE_H265WEB", get_env.("FEATURE_H265WEB"), false)

config :streamix,
  player_lifecycle_logs:
    RuntimeConfig.boolean!(
      "PLAYER_LIFECYCLE_LOGS",
      get_env.("PLAYER_LIFECYCLE_LOGS"),
      false
    )

# API Keys for TV app and external clients
# Comma-separated list of valid API keys
api_keys = RuntimeConfig.csv(get_env.("API_KEYS"))

if config_env() == :prod and api_keys == [] do
  raise "API_KEYS must contain at least one key in production"
end

config :streamix, :api_keys, api_keys

# CORS configuration
# Comma-separated list of allowed origins, or "*" for development
cors_origins =
  case get_env.("CORS_ORIGINS") do
    nil ->
      # Default: in prod use PHX_HOST, in dev allow localhost
      if config_env() == :prod do
        host = get_env.("PHX_HOST") || "example.com"
        ["https://#{host}"]
      else
        [
          "http://localhost:4000",
          "http://127.0.0.1:4000",
          # Vite Frontend
          "http://localhost:5173"
        ]
      end

    "*" ->
      # Explicitly allow all (not recommended for production)
      if config_env() == :prod do
        raise "CORS wildcard '*' is not allowed in production!"
      else
        :all
      end

    origins ->
      RuntimeConfig.csv(origins)
  end

config :streamix, :cors, origins: cors_origins

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/streamix start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if config_env() != :test and
     RuntimeConfig.boolean!("PHX_SERVER", get_env.("PHX_SERVER"), false) do
  config :streamix, StreamixWeb.Endpoint, server: true
end

# Test keeps the fixed port from config/test.exs (4002) so the suite can
# run alongside a dev server on 4000 — this stanza would otherwise
# deep-merge port 4000 over it.
if config_env() != :test do
  config :streamix, StreamixWeb.Endpoint,
    http: [
      port: RuntimeConfig.integer!("PORT", get_env.("PORT"), 4_000, min: 1, max: 65_535)
    ]
end

if config_env() == :prod do
  # Production-only tuning for the Repo (pool, queue timings, ssl, etc).
  # Base `url` and `socket_options` are set above for all environments.
  config :streamix, Streamix.Repo,
    pool_size: RuntimeConfig.integer!("POOL_SIZE", get_env.("POOL_SIZE"), 20, min: 1),
    # Tighter queue_target — used to be 5 s which let a single saturated
    # sync worker swallow web request connections for the full 5 s
    # before DBConnection started returning errors. 2 s is closer to a
    # human-perceptible threshold; queue_interval stays generous (5 s)
    # so the moving-average smooths over sync bursts.
    queue_target: 2_000,
    queue_interval: 5_000

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :streamix, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Parse allowed WebSocket origins from env or use host
  check_origin =
    case System.get_env("WEBSOCKET_ORIGINS") do
      nil -> ["//#{host}", "//localhost"]
      origins -> RuntimeConfig.csv(origins)
    end

  # LiveView signing salt - generate with: mix phx.gen.secret 32
  live_view_signing_salt =
    System.get_env("LIVE_VIEW_SIGNING_SALT") ||
      raise """
      environment variable LIVE_VIEW_SIGNING_SALT is missing.
      You can generate one by calling: mix phx.gen.secret 32
      """

  config :streamix, StreamixWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: RuntimeConfig.integer!("PORT", System.get_env("PORT"), 4_000, min: 1, max: 65_535),
      # Bandit performance tuning
      thousand_island_options: [
        transport_options: [keepalive: true]
      ],
      http_options: [
        response_encodings: [:zstd, :gzip, :deflate]
      ]
    ],
    check_origin: check_origin,
    secret_key_base: secret_key_base,
    live_view: [signing_salt: live_view_signing_salt]

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :streamix, StreamixWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :streamix, StreamixWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :streamix, Streamix.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
