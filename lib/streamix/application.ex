defmodule Streamix.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      StreamixWeb.Telemetry,
      Streamix.Repo,
      {Streamix.RateLimit, clean_period: :timer.minutes(10)},
      {Oban, Application.fetch_env!(:streamix, Oban)},
      {Redix, {redis_url(), [name: :streamix_redis]}},
      {DNSCluster, query: Application.get_env(:streamix, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Streamix.PubSub},
      # Content caching (categories, featured, stats)
      {ConCache,
       [
         name: :streamix_cache,
         ttl_check_interval: :timer.seconds(60),
         global_ttl: :timer.hours(1)
       ]},
      # Stream proxy for caching IPTV streams
      Streamix.Iptv.StreamProxy,
      # GIndex URL cache
      Streamix.Iptv.Gindex.UrlCache,
      # Start to serve requests, typically the last entry
      StreamixWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Streamix.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Initialize providers after supervisor starts
    init_providers()

    result
  end

  defp init_providers do
    # Run in a separate process to not block app startup
    Task.start(fn ->
      # Wait for Repo to be ready
      Process.sleep(1000)

      # Ensure GIndex provider exists if configured
      Streamix.Iptv.GIndexProvider.ensure_exists!()

      # Ensure Global provider exists if configured
      Streamix.Iptv.GlobalProvider.ensure_exists!()
    end)
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
