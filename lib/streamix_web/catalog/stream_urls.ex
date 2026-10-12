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
  follows the item's delivery (`Streamix.Playback.xtream_route/4`): an
  Xtream movie or episode stored as `m3u8` gets the HLS gateway's
  `/api/stream/hls/master.m3u8` URL; an item of a `direct_client_playback`
  provider is probed (once, then cached) and gets that master URL or the
  direct route `/api/stream/vod/direct.<container>`; everything else keeps
  the progressive token proxy. Behind the browser proxy the HLS master
  carries `edge=1`, which makes the gateway wrap every playlist reference in
  the same proxy, so a player that started there never leaves it. The direct
  route is never put behind that proxy: its egress is a server address the
  progressive CDN refuses, and the proxy would log the CDN URL.

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
      true -> signed_xtream_url(token, loaded_provider(movie), :movie, movie)
    end
  end

  def signed_episode_url(episode) do
    token = StreamToken.sign_episode(episode.id, nil, @sign_opts)

    if gindex_content?(episode),
      do: gindex_direct_url(token),
      else: signed_xtream_url(token, episode_provider(episode), :episode, episode)
  end

  # Channels are always live IPTV — never GIndex. They keep the live token
  # proxy unless their provider probes live delivery and the probe found HLS,
  # in which case the `.m3u8` gateway URL is minted.
  def signed_channel_url(channel) do
    token = StreamToken.sign_channel(channel.id, nil, @sign_opts)

    case Streamix.Playback.xtream_route(loaded_provider(channel), :channel, channel) do
      :hls -> hls_master_url(token)
      _proxy -> token_proxy_url(token)
    end
  end

  # ---------------------------------------------------------------------
  # Browser players (CORS-safe)
  # ---------------------------------------------------------------------

  def browser_movie_url(movie) do
    token = StreamToken.sign_movie(movie.id, nil, @sign_opts)

    if embedplay_content?(movie),
      do: embedplay_url(token),
      else: browser_xtream_url(token, loaded_provider(movie), :movie, movie)
  end

  def browser_episode_url(episode) do
    token = StreamToken.sign_episode(episode.id, nil, @sign_opts)
    browser_xtream_url(token, episode_provider(episode), :episode, episode)
  end

  def browser_channel_url(channel) do
    token = StreamToken.sign_channel(channel.id, nil, @sign_opts)

    case Streamix.Playback.xtream_route(loaded_provider(channel), :channel, channel) do
      :hls -> browser_hls_master_url(token)
      _proxy -> browser_token_proxy_url(token)
    end
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

  @doc """
  The direct-client route for a movie or episode token of a
  `direct_client_playback` provider. The suffix names the container the
  client receives after the redirect, so it picks a progressive engine.
  """
  def direct_url(token, extension),
    do: "#{endpoint_url()}/api/stream/vod/direct.#{extension}?token=#{URI.encode_www_form(token)}"

  @doc """
  The minted URL for an Xtream movie or episode token, by its route
  (`Streamix.Playback.xtream_route/4`).
  """
  def xtream_url(token, route) do
    case route do
      :hls -> hls_master_url(token)
      {:direct, extension} -> direct_url(token, extension)
      :proxy -> token_proxy_url(token)
    end
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

  defp signed_xtream_url(token, provider, type, content),
    do: xtream_url(token, Streamix.Playback.xtream_route(provider, type, content))

  defp browser_xtream_url(token, provider, type, content) do
    case Streamix.Playback.xtream_route(provider, type, content) do
      :hls -> browser_hls_master_url(token)
      {:direct, extension} -> direct_url(token, extension)
      :proxy -> browser_token_proxy_url(token)
    end
  end

  # Movies and channels carry their provider; without it preloaded the item
  # keeps the token proxy, which redirects by itself where it must.
  defp loaded_provider(%{provider: %{} = provider}), do: provider
  defp loaded_provider(_content), do: nil

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
