defmodule Streamix.Gindex.EndpointPolicy do
  @moduledoc """
  Defines GIndex endpoint roles and the failover pools that are safe to use.

  Not every mirror has the same capabilities. Folder listing may fail over
  across the known mirror pool, while playback only uses Workers verified to
  mint a token and serve byte ranges from that same host.
  """

  @verified_unified_url "https://animezey16082023.animezey16082023.workers.dev"
  @legacy_sync_url "https://1.animezey23112022.workers.dev"
  @legacy_stream_url "https://1.animezeydl.workers.dev"

  @default_sync_url @verified_unified_url
  @default_stream_url @verified_unified_url
  @known_urls [@verified_unified_url, @legacy_sync_url, @legacy_stream_url]
  @known_stream_urls [@verified_unified_url, @legacy_stream_url]

  @doc "Ordered endpoint pool used for folder listing and sync failover."
  def default_endpoints do
    [
      %{name: :unified_primary, url: @verified_unified_url, priority: 1},
      %{name: :sync_fallback, url: @legacy_sync_url, priority: 2},
      %{name: :stream_fallback, url: @legacy_stream_url, priority: 3}
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

  @doc "Ordered listing candidates, including safe known-mirror fallbacks."
  def listing_urls(
        config \\ Application.get_env(:streamix, :gindex_provider, []),
        preferred_url \\ nil
      )

  def listing_urls(config, preferred_url) when is_list(config) do
    configured = Keyword.get(config, :endpoints, [])
    primary = preferred_url || sync_url(config)
    candidates = [primary | configured]

    candidates
    |> maybe_append_known_urls()
    |> normalize_urls()
  end

  @doc "Ordered playback candidates restricted to mirrors verified for byte ranges."
  def stream_urls(
        config \\ Application.get_env(:streamix, :gindex_provider, []),
        provider_url \\ nil
      )

  def stream_urls(config, provider_url) when is_list(config) do
    primary = stream_url(config, provider_url)

    candidates =
      if known_url?(primary) do
        [primary | @known_stream_urls]
      else
        [primary]
      end

    normalize_urls(candidates)
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

  defp maybe_append_known_urls(urls) do
    if Enum.any?(urls, &known_url?/1), do: urls ++ @known_urls, else: urls
  end

  defp known_url?(url) when is_binary(url) do
    normalized = normalize_url(url)
    Enum.any?(@known_urls, &(normalize_url(&1) == normalized))
  end

  defp known_url?(_url), do: false

  defp normalize_urls(urls) do
    urls
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map(&normalize_url/1)
    |> Enum.uniq()
  end

  defp normalize_url(url), do: String.trim_trailing(String.trim(url), "/")
end
