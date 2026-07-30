import Config
import Dotenvy

defmodule Streamix.RuntimeDatabaseSafety do
  @moduledoc false

  @local_hosts ~w(localhost 127.0.0.1 ::1 postgres streamix-postgres)
  @remote_override "i-know-this-is-a-test-database"

  def remote_override, do: @remote_override

  def validate_test_url!(database_url, opts \\ [])

  def validate_test_url!(nil, _opts), do: nil

  def validate_test_url!(database_url, opts) when is_binary(database_url) do
    uri = URI.parse(database_url)
    host = normalize_host(uri.host)
    database = database_name(uri.path)
    allowed_hosts = @local_hosts ++ validate_compose_hosts!(Keyword.get(opts, :allowed_hosts, []))

    validate_test_database_name!(database)

    if Keyword.get(opts, :allow_remote?, false) or host in allowed_hosts do
      database_url
    else
      raise """
      refusing to run tests against remote database host #{inspect(host)} (database #{inspect(database)}).
      Set TEST_DATABASE_URL to localhost/a Compose database, or explicitly set
      ALLOW_REMOTE_TEST_DATABASE=#{@remote_override} for an intentional isolated remote test database.
      """
    end
  end

  defp normalize_host(host) when is_binary(host), do: String.downcase(host)
  defp normalize_host(_host), do: nil

  defp database_name("/" <> database) when database != "", do: URI.decode(database)
  defp database_name(_path), do: nil

  defp validate_compose_hosts!(hosts) do
    Enum.map(hosts, fn host ->
      normalized = normalize_host(host)

      if is_binary(normalized) and
           Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, normalized) do
        normalized
      else
        raise """
        refusing invalid TEST_DATABASE_ALLOWED_HOSTS entry #{inspect(host)}.
        Extra allowlisted hosts must be local Compose service names, not IP addresses or domains.
        """
      end
    end)
  end

  defp validate_test_database_name!(database) when is_binary(database) do
    if Regex.match?(~r/_test\d*\z/, database) do
      :ok
    else
      raise """
      refusing to run tests against database #{inspect(database)}.
      Test database names must end in _test (optionally followed by a partition number).
      """
    end
  end

  defp validate_test_database_name!(_database) do
    raise "refusing to run tests with a database URL that has no database name"
  end
end

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
        (get_env.("TEST_DATABASE_ALLOWED_HOSTS") || "")
        |> String.split(",", trim: true)
        |> Enum.map(&(String.trim(&1) |> String.downcase()))
        |> Enum.reject(&(&1 == ""))

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

maybe_ipv6 = if get_env.("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

repo_pool_size =
  case config_env() do
    :test ->
      String.to_integer(
        get_env.("TEST_POOL_SIZE") || Integer.to_string(System.schedulers_online() * 2)
      )

    _ ->
      String.to_integer(get_env.("POOL_SIZE") || "10")
  end

config :streamix, Streamix.Repo,
  url: database_url,
  pool_size: repo_pool_size,
  migration_lock: :pg_advisory_lock,
  socket_options: maybe_ipv6

# Redis URL (loaded from .env in dev/test via Dotenvy, System env in prod)
config :streamix, :redis_url, get_env.("REDIS_URL") || "redis://localhost:6379"

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
if get_env.("GLOBAL_PROVIDER_ENABLED") == "true" do
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
# Additional profiles may override the api_token to isolate quotas per
# ingestion source. `GINDEX_TMDB_API_TOKEN` feeds profile `:gindex`.
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

# GIndex pacer budgets (requests-per-second). Tunable from the env
# without a code change — useful when upstream capacity changes.
config :streamix, Streamix.Gindex.Pacer,
  # 1 q/s. The free Cloudflare Workers tier the upstream
  # `*.workers.dev` instances run on has a daily ceiling of ~10K req
  # account-wide; at 3 q/s we ate the budget in under an hour and got
  # rate-limited (503) for the remainder. Override with GINDEX_GDRIVE_RPS
  # if you control the upstream and want to push it.
  gdrive: String.to_integer(get_env.("GINDEX_GDRIVE_RPS") || "1"),
  tmdb_gindex: String.to_integer(get_env.("GINDEX_TMDB_RPS") || "10"),
  anilist: String.to_integer(get_env.("GINDEX_ANILIST_RPS") || "1"),
  tomato: String.to_integer(get_env.("GINDEX_TOMATO_RPS") || "2")

config :streamix, Streamix.Gindex.Pagination,
  delay_ms: String.to_integer(get_env.("GINDEX_PAGE_DELAY_MS") || "5000"),
  jitter_ms: String.to_integer(get_env.("GINDEX_PAGE_JITTER_MS") || "1000")

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
if get_env.("GINDEX_ENABLED") == "true" do
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
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(validate_gindex_url)
        |> Enum.uniq()

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
if config_env() != :test and get_env.("TORRENT_ENABLED") == "true" do
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
       config_env() == :prod and get_env.("OBAN_RECOVER_ORPHANED_ON_STARTUP") != "false"

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
  enabled: config_env() != :test and get_env.("QDRANT_ENABLED") != "false",
  url: get_env.("QDRANT_URL") || "http://localhost:6333",
  api_key: get_env.("QDRANT_API_KEY")

# RabbitMQ configuration for Broadway distributed workers
# Set RABBITMQ_ENABLED=true to enable
if get_env.("RABBITMQ_ENABLED") == "true" do
  config :streamix, :rabbitmq,
    enabled: true,
    connection: [
      host: get_env.("RABBITMQ_HOST") || "localhost",
      port: String.to_integer(get_env.("RABBITMQ_PORT") || "5672"),
      username: get_env.("RABBITMQ_USERNAME") || "guest",
      password: get_env.("RABBITMQ_PASSWORD") || "guest",
      virtual_host: get_env.("RABBITMQ_VHOST") || "/"
    ],
    broadway: [
      # Keep at 1 to avoid GIndex rate limiting (tasks run sequentially)
      processor_concurrency: String.to_integer(get_env.("BROADWAY_CONCURRENCY") || "1"),
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
  case get_env.("STREAM_PROXY_URLS") do
    csv when is_binary(csv) and csv != "" ->
      csv
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    _ ->
      []
  end

case get_env.("STREAM_PROXY_BACKEND") do
  "redirect" -> config :streamix, :stream_proxy_backend, :redirect
  "beam" -> config :streamix, :stream_proxy_backend, :beam
  _ -> :ok
end

config :streamix,
  stream_proxy_url: get_env.("STREAM_PROXY_URL") || "https://source.mahina.cloud",
  stream_proxy_urls: stream_proxy_urls,
  tmdb_proxy_url: get_env.("TMDB_PROXY_URL") || "https://tmdb.mahina.cloud",
  imgmxa_proxy_url: get_env.("IMGMXA_PROXY_URL") || "https://imgmxa.mahina.cloud",
  image_proxy_url: get_env.("IMAGE_PROXY_URL") || "https://img.mahina.cloud",
  # Shared HMAC secret used by `Streamix.Iptv.Streaming.SourceUrl` to
  # build signed URLs the browser can hit on `source.mahina.cloud`
  # directly — bypasses the Phoenix `/api/stream/proxy` 302 hop. The
  # nginx Lua verifier on the VPS must use the same value. When unset
  # (dev / tests) we fall back to the token-redirect path.
  source_proxy_shared_secret: get_env.("SOURCE_PROXY_SHARED_SECRET"),
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
  feature_avbridge: (get_env.("FEATURE_AVBRIDGE") || "false") == "true",
  # Opt the browser into the h265web.js engine for GIndex MKV/HEVC
  # content. Alternate GPU path; needs SAB + COOP+COEP headers to
  # actually run multi-threaded decode (without them the SDK boots
  # but the AudioContext/decoder pipeline never starts). Off by
  # default; flip when the headers are wired.
  feature_h265web: (get_env.("FEATURE_H265WEB") || "false") == "true"

config :streamix,
  player_lifecycle_logs: get_env.("PLAYER_LIFECYCLE_LOGS") in ~w(true 1 yes)

# API Keys for TV app and external clients
# Comma-separated list of valid API keys
api_keys =
  case get_env.("API_KEYS") do
    nil -> []
    "" -> []
    keys -> String.split(keys, ",") |> Enum.map(&String.trim/1)
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
      String.split(origins, ",") |> Enum.map(&String.trim/1)
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
if config_env() != :test and get_env.("PHX_SERVER") do
  config :streamix, StreamixWeb.Endpoint, server: true
end

# Test keeps the fixed port from config/test.exs (4002) so the suite can
# run alongside a dev server on 4000 — this stanza would otherwise
# deep-merge port 4000 over it.
if config_env() != :test do
  config :streamix, StreamixWeb.Endpoint,
    http: [port: String.to_integer(get_env.("PORT") || "4000")]
end

if config_env() == :prod do
  # Production-only tuning for the Repo (pool, queue timings, ssl, etc).
  # Base `url` and `socket_options` are set above for all environments.
  config :streamix, Streamix.Repo,
    pool_size: String.to_integer(get_env.("POOL_SIZE") || "20"),
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
      origins -> String.split(origins, ",") |> Enum.map(&String.trim/1)
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
      port: String.to_integer(System.get_env("PORT") || "4000"),
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
