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
      {Oban, Application.fetch_env!(:streamix, Oban)},
      {Redix, {redis_url(), [name: :streamix_redis]}},
      {DNSCluster, query: Application.get_env(:streamix, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Streamix.PubSub},
      # Rate limiting backend using ETS
      {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60, cleanup_interval_ms: 60_000 * 10]},
      # Content caching (categories, featured, stats)
      {ConCache,
       [
         name: :streamix_cache,
         ttl_check_interval: :timer.seconds(60),
         global_ttl: :timer.hours(1)
       ]},
      # Stream proxy for caching IPTV streams
      Streamix.Iptv.StreamProxy,
      # Start to serve requests, typically the last entry
      StreamixWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Streamix.Supervisor]
    Supervisor.start_link(children, opts)
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
