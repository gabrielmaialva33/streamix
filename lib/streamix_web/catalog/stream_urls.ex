defmodule StreamixWeb.Catalog.StreamUrls do
  @moduledoc """
  Builds signed stream URLs for catalog payloads.

  Wraps `StreamixWeb.StreamToken` so the public catalog API can expose
  token-based proxy URLs without ever leaking upstream credentials to
  clients.

  Two URL flavours are produced:

    * `signed_*_url/1` — token-based proxy for AVPlay on Tizen (works
      with any format).
    * `browser_*_url/1` — routed through the `source.mahina.fun`
      browser proxy to handle CORS for web players.

  All catalog endpoints are behind the `:api_v1` pipeline which runs
  `StreamixWeb.Plugs.ApiKeyAuth` — so by the time we reach a catalog
  action, the caller has proved integration-level authorization. We embed
  that authorization inside the signed token so the stream proxy can
  bypass the subscription check even when the URL is later fetched
  through an intermediate proxy (e.g. `source.mahina.fun`) that doesn't
  forward the `X-API-Key` header.
  """

  alias StreamixWeb.StreamToken

  @sign_opts [bypass_subscription: true]

  # ---------------------------------------------------------------------
  # Tizen / native players
  # ---------------------------------------------------------------------

  def signed_movie_url(movie) do
    token = StreamToken.sign_movie(movie.id, nil, @sign_opts)
    if gindex_content?(movie), do: gindex_direct_url(token), else: token_proxy_url(token)
  end

  def signed_episode_url(episode) do
    token = StreamToken.sign_episode(episode.id, nil, @sign_opts)
    if gindex_content?(episode), do: gindex_direct_url(token), else: token_proxy_url(token)
  end

  def signed_channel_url(channel) do
    # Channels are always live IPTV — never GIndex — so they always go
    # through the legacy token proxy flow.
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

  # GIndex VOD content (movies + episodes with a non-empty `gindex_path`)
  # streams from a dedicated nginx hop at `gindex.mahina.fun`. The
  # nginx side hits our resolve-only endpoint over the tunnel, gets the
  # `download.aspx` URL, and pumps bytes back to the player without
  # ever touching the BEAM. Falsy `:gindex_direct_proxy_url` disables
  # the direct route — useful in dev where we don't run nginx.
  defp gindex_direct_url(token) do
    case Application.get_env(:streamix, :gindex_direct_proxy_url) do
      base when is_binary(base) and base != "" ->
        normalized = String.trim_trailing(base, "/")
        "#{normalized}/stream?token=#{URI.encode_www_form(token)}"

      _ ->
        token_proxy_url(token)
    end
  end

  defp gindex_content?(%{gindex_path: path}) when is_binary(path) and path != "", do: true
  defp gindex_content?(_), do: false

  defp browser_token_proxy_url(token) do
    proxy_base = Application.get_env(:streamix, :stream_proxy_url, "https://source.mahina.fun")
    token_url = token_proxy_url(token)
    "#{proxy_base}/proxy?url=#{URI.encode_www_form(token_url)}"
  end

  defp endpoint_url do
    :streamix
    |> Application.get_env(StreamixWeb.Endpoint, [])
    |> Keyword.get(:url, [])
    |> url_from_endpoint_config()
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
