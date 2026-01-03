defmodule Streamix.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        StreamixWeb.Telemetry,
        Streamix.Repo,
        {Streamix.RateLimit, clean_period: :timer.minutes(10)},
        {Oban, Application.fetch_env!(:streamix, Oban)},
        {Redix, {redis_url(), [name: :streamix_redis]}},
        # L1 in-memory cache (ConCache) for hot data
        {ConCache,
         [
           name: :streamix_l1_cache,
           ttl_check_interval: :timer.seconds(30),
           global_ttl: :timer.hours(1),
           touch_on_read: true
         ]},
        # HTTP connection pool for sync operations (high concurrency)
        {Finch,
         name: Streamix.Finch,
         pools: %{
           # Default pool for API calls during sync
           :default => [size: 50, count: 4]
         }},
        {DNSCluster, query: Application.get_env(:streamix, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Streamix.PubSub},
        # NOTE: Content caching uses Redis via Streamix.Cache (cluster-ready)
        # Stream proxy for caching IPTV streams
        Streamix.Iptv.StreamProxy,
        # GIndex URL cache
        Streamix.Iptv.Gindex.UrlCache,
        # Start to serve requests, typically the last entry
        StreamixWeb.Endpoint
      ] ++ Streamix.Queue.Supervisor.child_spec_if_enabled()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Streamix.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Initialize providers after supervisor starts
    init_providers()

    result
  end

  defp init_providers do
    # Skip provider initialization during tests (Sandbox mode doesn't work with spawned tasks)
    unless Application.get_env(:streamix, :env) == :test do
      # Run in a separate process to not block app startup
      Task.start(fn ->
        wait_for_repo_with_retry()
        init_system_providers()
      end)
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
    System.get_env("REDIS_URL", "redis://localhost:6379")
  end
end
