defmodule Streamix.Gindex.EndpointPolicyTest do
  use ExUnit.Case, async: true

  alias Streamix.Gindex.EndpointPolicy

  test "uses the verified unified Worker for sync and playback by default" do
    config = [enabled: true]

    assert EndpointPolicy.sync_url(config) ==
             "https://animezey16082023.animezey16082023.workers.dev"

    assert EndpointPolicy.stream_url(config, "https://stale-provider.example.com") ==
             "https://animezey16082023.animezey16082023.workers.dev"
  end

  test "keeps the legacy single URL configuration for both roles" do
    config = [enabled: true, url: "https://custom.example.com"]

    assert EndpointPolicy.sync_url(config) == "https://custom.example.com"
    assert EndpointPolicy.stream_url(config, nil) == "https://custom.example.com"
  end

  test "honors explicit role overrides" do
    config = [
      enabled: true,
      sync_url: "https://sync.example.com",
      stream_url: "https://stream.example.com",
      url: "https://legacy.example.com"
    ]

    assert EndpointPolicy.sync_url(config) == "https://sync.example.com"
    assert EndpointPolicy.stream_url(config, nil) == "https://stream.example.com"
  end

  test "does not mistake the sync compatibility URL for a stream endpoint" do
    config = [
      enabled: true,
      sync_url: "https://sync.example.com",
      url: "https://sync.example.com"
    ]

    assert EndpointPolicy.stream_url(config, nil) ==
             "https://animezey16082023.animezey16082023.workers.dev"
  end

  test "adds known mirrors as listing fallbacks without changing custom pools" do
    assert EndpointPolicy.listing_urls(
             [enabled: true, sync_url: "https://1.animezey23112022.workers.dev"],
             nil
           ) == [
             "https://1.animezey23112022.workers.dev",
             "https://animezey16082023.animezey16082023.workers.dev",
             "https://1.animezeydl.workers.dev"
           ]

    assert EndpointPolicy.listing_urls(
             [enabled: true, sync_url: "https://private.example.com"],
             nil
           ) == ["https://private.example.com"]
  end

  test "only adds byte-range capable mirrors to playback failover" do
    assert EndpointPolicy.stream_urls(
             [enabled: true, stream_url: "https://1.animezeydl.workers.dev"],
             nil
           ) == [
             "https://1.animezeydl.workers.dev",
             "https://animezey16082023.animezey16082023.workers.dev"
           ]

    assert EndpointPolicy.stream_urls(
             [enabled: true, stream_url: "https://private.example.com"],
             nil
           ) == ["https://private.example.com"]
  end
end
