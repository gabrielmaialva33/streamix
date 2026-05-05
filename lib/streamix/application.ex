defmodule Streamix.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Streamix.Iptv.Gindex.SingleFlight

  @impl true
  def start(_type, _args) do
    # Configure DNS resolution to avoid stale cache issues in containers
    # The BEAM's default inet resolver can cache DNS indefinitely
    configure_dns_resolver()

    children =
      [
        StreamixWeb.Telemetry,
        Streamix.Repo,
        {Streamix.RateLimit, clean_period: :timer.minutes(10)},
        {Oban, Application.fetch_env!(:streamix, Oban)},
        {Task.Supervisor, name: Streamix.TaskSupervisor},
        {Redix, {redis_url(), [name: :streamix_redis]}},
        # L1 in-memory cache (ConCache) for hot data
        {ConCache,
         [
           name: :streamix_l1_cache,
           ttl_check_interval: Streamix.Cache.l1_ttl_check_interval(),
           global_ttl: Streamix.Cache.l1_ttl(),
           touch_on_read: true
         ]},
        # HTTP connection pool for sync operations (high concurrency)
        # conn_opts includes DNS cache timeout to avoid stale connections
        {Finch,
         name: Streamix.Finch,
         pools: %{
           # Default pool for API calls during sync
           # conn_max_idle_time forces connection refresh for DNS changes
           :default => [
             size: 50,
             count: 4,
             conn_max_idle_time: :timer.minutes(1)
           ]
         }},
        # Dedicated pool for long-lived VOD/Live proxy sockets. Keeping
        # it separate prevents player traffic from exhausting checkout
        # capacity needed by sync, image, metadata and health requests.
        {Finch, name: Streamix.StreamFinch, pools: stream_finch_pools()},
        {DNSCluster, query: Application.get_env(:streamix, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Streamix.PubSub},
        # NOTE: Content caching uses Redis via Streamix.Cache (cluster-ready)
        # Stream proxy for caching IPTV streams
        Streamix.Iptv.StreamProxy,
        # Redirect-chain resolution cache (single-flight) — keeps the
        # first /api/stream/proxy hit fast by piggy-backing on a prewarm
        # task fired from PlayerLive.mount/3.
        Streamix.Iptv.Streaming.RedirectResolver,
        # GIndex endpoint manager (multi-endpoint failover)
        Streamix.Iptv.Gindex.EndpointManager,
        # GIndex URL cache
        Streamix.Iptv.Gindex.UrlCache,
        # Xtream circuit breaker (Netflix-style resilience)
        Streamix.Iptv.XtreamCircuitBreaker,
        # Background provider-health sampler — keeps ETS warm so LV
        # mounts don't block on the 4s upstream probe.
        Streamix.Iptv.ProviderHealthMonitor,
        # Stream multiplexer infrastructure (1 upstream → N downstream)
        {Registry, keys: :unique, name: Streamix.StreamRegistry},
        {Streamix.Iptv.StreamMultiplexerSupervisor, []},
        # Watch Party infrastructure
        {Registry, keys: :unique, name: Streamix.WatchParty.Registry},
        {DynamicSupervisor, name: Streamix.WatchParty.RoomSupervisor, strategy: :one_for_one},
        StreamixWeb.Presence,
        # Start to serve requests, typically the last entry
        StreamixWeb.Endpoint
      ] ++ Streamix.Queue.Supervisor.child_spec_if_enabled()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Streamix.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Initialize providers after supervisor starts
    init_providers()

    # Bootstrap the GIndex single-flight ETS table. Public, named, no
    # GenServer needed — the table lives for the life of the BEAM node.
    SingleFlight.setup()

    result
  end

  defp init_providers do
    # Skip provider initialization during tests (Sandbox mode doesn't work with spawned tasks)
    unless Application.get_env(:streamix, :env) == :test do
      # Run in a separate process to not block app startup
      case Streamix.TaskLauncher.start_child(fn ->
             wait_for_repo_with_retry()
             init_system_providers()
           end) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          require Logger

          Logger.warning(
            "[Application] Failed to start provider initialization task: #{inspect(reason)}"
          )
      end
    end
  end

  # Wait for Repo to be ready with exponential backoff
  defp wait_for_repo_with_retry(attempts \\ 0, max_attempts \\ 10) do
    case Streamix.Repo.query("SELECT 1") do
      {:ok, _} ->
        :ok

      {:error, _} when attempts < max_attempts ->
        # Exponential backoff: 100ms, 200ms, 400ms, ...
        delay = min(:timer.seconds(5), (100 * :math.pow(2, attempts)) |> trunc())
        Process.sleep(delay)
        wait_for_repo_with_retry(attempts + 1, max_attempts)

      {:error, reason} ->
        require Logger

        Logger.warning(
          "[Application] Repo not ready after #{max_attempts} attempts: #{inspect(reason)}"
        )

        :error
    end
  end

  defp init_system_providers do
    alias Streamix.Iptv.{GIndexProvider, GlobalProvider}
    require Logger

    # Ensure GIndex provider exists if configured
    case GIndexProvider.ensure_exists!() do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Application] GIndex provider init failed: #{inspect(reason)}")
    end

    # Ensure Global provider exists if configured
    case GlobalProvider.ensure_exists!() do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Application] Global provider init failed: #{inspect(reason)}")
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    StreamixWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp redis_url do
    Application.get_env(:streamix, :redis_url, "redis://localhost:6379")
  end

  defp stream_finch_pools do
    Application.get_env(:streamix, :stream_finch_pools, %{
      :default => [
        size: 25,
        count: 4,
        # Finch currently documents HTTP/2 response streaming as having no
        # backpressure mechanism, which is a poor fit for large media bodies.
        protocols: [:http1],
        conn_max_idle_time: :timer.seconds(10),
        pool_max_idle_time: :timer.minutes(5)
      ]
    })
  end

  # Configure Erlang's DNS resolver to avoid stale cache in containers
  # This is critical for Cloudflare Workers endpoints that use anycast IPs
  defp configure_dns_resolver do
    # Use inet_res (native Erlang resolver) with short cache TTL
    # instead of the default inet resolver which can cache indefinitely
    :inet_db.set_lookup([:dns, :file, :native])

    # Set DNS cache timeout to 60 seconds (default is infinity in some cases)
    # This forces re-resolution for hostnames after TTL expires
    :inet_db.set_cache_refresh(60_000)

    # Clear any existing DNS cache on startup
    :inet_db.clear_cache()

    :ok
  rescue
    # If inet_db operations fail, log warning but don't crash
    error ->
      require Logger
      Logger.warning("[DNS] Failed to configure resolver: #{inspect(error)}")
      :ok
  end
end
