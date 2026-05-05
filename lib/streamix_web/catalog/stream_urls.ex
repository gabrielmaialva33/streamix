defmodule StreamixWeb.Catalog.StreamUrls do
  @moduledoc """
  Builds signed stream URLs for catalog payloads.

  Wraps `StreamixWeb.StreamToken` so the public catalog API can expose
  token-based proxy URLs without ever leaking upstream credentials to
  clients.

  Two URL flavours are produced:

    * `signed_*_url/1` — token-based proxy for AVPlay on Tizen (works
      with any format).
    * `browser_*_url/1` — routed through the `source.mahina.cloud`
      browser proxy to handle CORS for web players.

  All catalog endpoints are behind the `:api_v1` pipeline which runs
  `StreamixWeb.Plugs.ApiKeyAuth` — so by the time we reach a catalog
  action, the caller has proved integration-level authorization. We embed
  that authorization inside the signed token so the stream proxy can
  bypass the subscription check even when the URL is later fetched
  through an intermediate proxy (e.g. `source.mahina.cloud`) that doesn't
  forward the `X-API-Key` header.
  """

  alias StreamixWeb.StreamToken

  @sign_opts [bypass_subscription: true]

  # ---------------------------------------------------------------------
  # Tizen / native players
  # ---------------------------------------------------------------------

  def signed_movie_url(movie) do
    movie.id
    |> StreamToken.sign_movie(nil, @sign_opts)
    |> token_proxy_url()
  end

  def signed_episode_url(episode) do
    episode.id
    |> StreamToken.sign_episode(nil, @sign_opts)
    |> token_proxy_url()
  end

  def signed_channel_url(channel) do
    channel.id
    |> StreamToken.sign_channel(nil, @sign_opts)
    |> token_proxy_url()
  end

  # ---------------------------------------------------------------------
  # Browser players (CORS-safe)
  # ---------------------------------------------------------------------

  def browser_movie_url(movie) do
    movie.id
    |> StreamToken.sign_movie(nil, @sign_opts)
    |> browser_token_proxy_url()
  end

  def browser_episode_url(episode) do
    episode.id
    |> StreamToken.sign_episode(nil, @sign_opts)
    |> browser_token_proxy_url()
  end

  def browser_channel_url(channel) do
    channel.id
    |> StreamToken.sign_channel(nil, @sign_opts)
    |> browser_token_proxy_url()
  end

  # ---------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------

  defp token_proxy_url(token) do
    "#{endpoint_url()}/api/stream/proxy?token=#{URI.encode_www_form(token)}"
  end

  defp browser_token_proxy_url(token) do
    proxy_base = Application.get_env(:streamix, :stream_proxy_url, "https://source.mahina.cloud")
    token_url = token_proxy_url(token)
    "#{proxy_base}/proxy?url=#{URI.encode_www_form(token_url)}"
  end

  defp endpoint_url do
    :streamix
    |> Application.get_env(endpoint_module(), [])
    |> Keyword.get(:url, [])
    |> url_from_endpoint_config()
  end

  defp endpoint_module do
    Module.concat(["StreamixWeb", "Endpoint"])
  end

  defp url_from_endpoint_config(config) do
    scheme = Keyword.get(config, :scheme, "http")
    host = Keyword.get(config, :host, "localhost")
    port = Keyword.get(config, :port)

    scheme <> "://" <> host <> port_suffix(scheme, port)
  end

  defp port_suffix(_scheme, nil), do: ""
  defp port_suffix("http", 80), do: ""
  defp port_suffix("https", 443), do: ""
  defp port_suffix(_scheme, port), do: ":#{port}"
end
