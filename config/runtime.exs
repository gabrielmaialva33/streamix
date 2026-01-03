import Config
import Dotenvy

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

# TMDB API configuration (optional, for enriched movie metadata)
if tmdb_token = get_env.("TMDB_API_TOKEN") do
  config :streamix, :tmdb,
    enabled: true,
    api_token: tmdb_token
else
  config :streamix, :tmdb, enabled: false
end

# GIndex provider configuration (Google Drive Index for movies/series/animes)
# Paths are configured via gindex_drives on the provider record
if get_env.("GINDEX_ENABLED") == "true" do
  config :streamix, :gindex_provider,
    enabled: true,
    url: get_env.("GINDEX_URL")
else
  config :streamix, :gindex_provider, enabled: false
end

# AI Embeddings configuration for semantic search
# Set EMBEDDING_PROVIDER to choose: "gemini" (default) or "nvidia"
# Both can be configured for automatic fallback
config :streamix, :embeddings, provider: get_env.("EMBEDDING_PROVIDER") || "gemini"

# Gemini AI configuration for embeddings (3072 dimensions)
if gemini_api_key = get_env.("GEMINI_API_KEY") do
  config :streamix, :gemini, api_key: gemini_api_key
end

# NVIDIA NIM configuration for embeddings (1024 dimensions)
if nvidia_api_key = get_env.("NVIDIA_API_KEY") do
  config :streamix, :nvidia,
    api_key: nvidia_api_key,
    embedding_model: get_env.("NVIDIA_EMBEDDING_MODEL") || "nv-embedqa-e5-v5"
end

# Qdrant vector database configuration
# Required for semantic search functionality
config :streamix, :qdrant,
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
      processor_concurrency: String.to_integer(get_env.("BROADWAY_CONCURRENCY") || "5"),
      batcher_concurrency: 2,
      batch_size: 10,
      batch_timeout: 2_000
    ]
end

# Stream proxy URL for bypassing mixed content blocking
# This reverse proxy handles HTTP IPTV streams over HTTPS
config :streamix,
  stream_proxy_url: get_env.("STREAM_PROXY_URL") || "https://pannxs.mahina.cloud"

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
        ["http://localhost:4000", "http://127.0.0.1:4000"]
      end

    "*" ->
      # Explicitly allow all (not recommended for production)
      :all

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
if get_env.("PHX_SERVER") do
  config :streamix, StreamixWeb.Endpoint, server: true
end

config :streamix, StreamixWeb.Endpoint,
  http: [port: String.to_integer(get_env.("PORT") || "4000")]

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :streamix, Streamix.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

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

  config :streamix, StreamixWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

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
