defmodule Streamix.Gindex.EndpointPolicy do
  @moduledoc """
  Defines the distinct GIndex endpoint roles.

  The two Workers expose the same catalog paths, but they don't have the same
  capabilities. Sync uses the Worker with the most reliable folder traversal,
  while playback resolves a fresh download token on the Worker that correctly
  serves byte ranges.
  """

  @default_sync_url "https://1.animezey23112022.workers.dev"
  @default_stream_url "https://1.animezeydl.workers.dev"

  @doc "Ordered endpoint pool used for folder listing and sync failover."
  def default_endpoints do
    [
      %{name: :sync_primary, url: @default_sync_url, priority: 1},
      %{name: :stream_primary, url: @default_stream_url, priority: 2}
    ]
  end

  @doc "Returns the configured sync endpoint, falling back to the verified default."
  def sync_url(config \\ Application.get_env(:streamix, :gindex_provider, []))
      when is_list(config) do
    Keyword.get(config, :sync_url) ||
      Keyword.get(config, :url) ||
      first_endpoint(config) ||
      @default_sync_url
  end

  @doc """
  Returns the endpoint that must mint and serve download tokens.

  When GIndex is enabled without an explicit URL, the verified stream Worker is
  preferred over a provider row that may still contain an old sync URL. In
  tests or provider-specific calls without global GIndex enabled, the provider
  URL remains the fallback.
  """
  def stream_url(provider_url \\ nil) do
    stream_url(Application.get_env(:streamix, :gindex_provider, []), provider_url)
  end

  def stream_url(config, provider_url) when is_list(config) do
    Keyword.get(config, :stream_url) ||
      legacy_stream_url(config) ||
      enabled_default_or_provider(config, provider_url)
  end

  defp first_endpoint(config) do
    case Keyword.get(config, :endpoints) do
      [url | _] when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  defp legacy_stream_url(config) do
    if Keyword.has_key?(config, :sync_url), do: nil, else: Keyword.get(config, :url)
  end

  defp enabled_default_or_provider(config, provider_url) do
    if Keyword.get(config, :enabled, false) do
      @default_stream_url
    else
      provider_url || @default_stream_url
    end
  end
end
