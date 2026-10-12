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

  Every client picks its playback engine from the URL suffix, so the route
  follows the item's delivery (`Streamix.Playback.xtream_delivery/2`): an
  Xtream movie or episode stored as `m3u8` gets the HLS gateway's
  `/api/stream/hls/master.m3u8` URL, everything else the progressive token
  proxy. Behind the browser proxy the HLS master carries `edge=1`, which makes
  the gateway wrap every playlist reference in the same proxy, so a player
  that started there never leaves it.

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

    cond do
      embedplay_content?(movie) -> embedplay_url(token)
      gindex_content?(movie) -> gindex_direct_url(token)
      hls_content?(movie_provider(movie), movie) -> hls_master_url(token)
      true -> token_proxy_url(token)
    end
  end

  def signed_episode_url(episode) do
    token = StreamToken.sign_episode(episode.id, nil, @sign_opts)

    cond do
      gindex_content?(episode) -> gindex_direct_url(token)
      hls_content?(episode_provider(episode), episode) -> hls_master_url(token)
      true -> token_proxy_url(token)
    end
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
    token = StreamToken.sign_movie(movie.id, nil, @sign_opts)

    cond do
      embedplay_content?(movie) -> embedplay_url(token)
      hls_content?(movie_provider(movie), movie) -> browser_hls_master_url(token)
      true -> browser_token_proxy_url(token)
    end
  end

  def browser_episode_url(episode) do
    token = StreamToken.sign_episode(episode.id, nil, @sign_opts)

    if hls_content?(episode_provider(episode), episode),
      do: browser_hls_master_url(token),
      else: browser_token_proxy_url(token)
  end

  def browser_channel_url(channel) do
    channel.id
    |> StreamToken.sign_channel(nil, @sign_opts)
    |> browser_token_proxy_url()
  end

  # ---------------------------------------------------------------------
  # HLS gateway URL contract
  # ---------------------------------------------------------------------

  @doc """
  The HLS gateway master URL for a movie or episode token. Its `.m3u8`
  suffix makes every player choose its HLS engine.
  """
  def hls_master_url(token),
    do: "#{endpoint_url()}/api/stream/hls/master.m3u8?token=#{URI.encode_www_form(token)}"

  @doc """
  The HLS master as reached through the browser stream proxy. `edge=1` tells
  the gateway to wrap every playlist reference in the same proxy.
  """
  def browser_hls_master_url(token), do: edge_url(hls_master_url(token) <> "&edge=1")

  @doc """
  A gateway resource URL as written into a rewritten playlist. Without
  `edge?` it is root-relative, so it resolves against whichever Streamix
  origin served the playlist; with `edge?` it is the absolute resource URL
  wrapped in the browser stream proxy.
  """
  def hls_resource_url(session_id, resource_id, token, edge?) do
    path =
      "/api/stream/hls/#{session_id}/#{resource_id}?token=#{URI.encode_www_form(token)}"

    if edge?, do: edge_url(endpoint_url() <> path <> "&edge=1"), else: path
  end

  # ---------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------

  defp token_proxy_url(token) do
    "#{endpoint_url()}/api/stream/proxy?token=#{URI.encode_www_form(token)}"
  end

  # The `.mp4` suffix is what makes every client pick progressive playback
  # (the web player and both TV backends route any `.m3u8` URL to HLS).
  defp embedplay_url(token),
    do: "#{endpoint_url()}/api/stream/embedplay/video.mp4?token=#{URI.encode_www_form(token)}"

  defp embedplay_content?(%{provider: %{provider_type: :embedplay}}), do: true
  defp embedplay_content?(_), do: false

  defp hls_content?(provider, content),
    do: match?({:hls, _}, Streamix.Playback.xtream_delivery(provider, content))

  defp movie_provider(%{provider: %{} = provider}), do: provider
  defp movie_provider(_movie), do: nil

  # Catalog episode payloads preload season → series → provider. Without it
  # the episode keeps the token proxy, which redirects HLS items itself.
  defp episode_provider(%{season: %{series: %{provider: %{} = provider}}}), do: provider
  defp episode_provider(_episode), do: nil

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

  defp browser_token_proxy_url(token), do: edge_url(token_proxy_url(token))

  defp edge_url(url) do
    proxy_base = Application.get_env(:streamix, :stream_proxy_url, "https://source.mahina.fun")
    "#{String.trim_trailing(proxy_base, "/")}/proxy?url=#{URI.encode_www_form(url)}"
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
