defmodule Streamix.Gindex.EndpointPolicyTest do
  use ExUnit.Case, async: true

  alias Streamix.Gindex.EndpointPolicy

  test "assigns the verified Workers to distinct sync and stream roles" do
    config = [enabled: true]

    assert EndpointPolicy.sync_url(config) ==
             "https://1.animezey23112022.workers.dev"

    assert EndpointPolicy.stream_url(config, "https://stale-provider.example.com") ==
             "https://1.animezeydl.workers.dev"
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
             "https://1.animezeydl.workers.dev"
  end
end
