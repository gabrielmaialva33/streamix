defmodule Streamix.Iptv.Streaming.XtreamDelivery do
  @moduledoc """
  Decides how an Xtream VOD item (movie or episode) reaches a player.

  `mode/2` is the cheap, static answer:

    * `:probe` — the provider has `direct_client_playback`: its catalogue
      `container_extension` is not a reliable delivery format, so the item
      is probed at play time (`Streamix.Iptv.Streaming.DeliveryProbe`) and
      plays either through the HLS gateway or by a redirect of the client to
      the progressive CDN;
    * `{:hls, "m3u8"}` — the item's `container_extension` is `m3u8`: its
      Xtream URL answers an HLS master playlist, served by the HLS gateway
      (`Streamix.Iptv.Streaming.XtreamHls`);
    * `:proxy` — everything else keeps the progressive token proxy.

  `route/4` turns that into the route a player must be given — every client
  picks its playback engine from the URL suffix, so URL minting, the token
  proxy's redirect and the gateways' own authorization all ask this module
  and never disagree. Only `:xtream` providers qualify; GIndex-backed rows
  keep their own route.
  """

  alias Streamix.Iptv.Streaming.DeliveryProbe
  alias Streamix.Iptv.XtreamClient

  @extension ~r/^[a-z0-9]{1,8}$/

  @type mode :: {:hls, String.t()} | :probe | :proxy
  @type route :: :hls | {:direct, String.t()} | :proxy
  @type item_type :: :movie | :episode

  @spec mode(map() | nil, map()) :: mode()
  def mode(%{provider_type: type} = provider, content)
      when type in [:xtream, "xtream"] and is_map(content) do
    cond do
      gindex?(content) -> :proxy
      Map.get(provider, :direct_client_playback) == true -> :probe
      extension(content) == "m3u8" -> {:hls, "m3u8"}
      true -> :proxy
    end
  end

  def mode(_provider, _content), do: :proxy

  @doc """
  The route a player must be given for `content`: `:hls` (an `.m3u8` gateway
  URL), `{:direct, extension}` (the direct route, suffixed with the
  container the client will receive) or `:proxy` (the token proxy).

  A `:probe` item is probed (or its cached decision reused); a failed probe
  answers `:proxy`, whose redirect reports the failure to the player. Pass
  `probe: false` where blocking on a probe is not worth it (a preload hint):
  a `:probe` item then answers `:proxy` unless a decision is already known.
  """
  @spec route(map() | nil, item_type(), map(), keyword()) :: route()
  def route(provider, type, content, opts \\ []) do
    case mode(provider, content) do
      {:hls, _extension} ->
        :hls

      :proxy ->
        :proxy

      :probe ->
        if Keyword.get(opts, :probe, true),
          do: probed_route(DeliveryProbe.decide(provider, type, content)),
          else: probed_route(DeliveryProbe.peek(provider, type, content))
    end
  end

  defp probed_route({:ok, {:hls, _url}}), do: :hls
  defp probed_route({:ok, {:direct, _url, extension}}), do: {:direct, extension}
  defp probed_route(_failure_or_miss), do: :proxy

  @doc """
  The upstream a gateway serves `content` from: `{:ok, {:hls, root_url}}`
  for the HLS gateway or `{:ok, {:direct, client_url, extension}}` for the
  direct route. Content that belongs on the token proxy fails with
  `:stream_format_mismatch`.

  `root_url` embeds the account credentials and is for server-side use only;
  `client_url` has passed `Streamix.Iptv.Streaming.DirectUrl`.
  """
  @spec resolve(map(), item_type(), map()) ::
          {:ok, {:hls, String.t()} | {:direct, String.t(), String.t()}} | {:error, atom()}
  def resolve(provider, type, content) do
    case mode(provider, content) do
      {:hls, extension} -> {:ok, {:hls, stream_url(provider, type, content, extension)}}
      :probe -> DeliveryProbe.decide(provider, type, content)
      :proxy -> {:error, :stream_format_mismatch}
    end
  end

  @doc """
  The item's normalized container extension (`"mp4"` when absent, as in the
  Xtream URL builder), or `nil` when the stored value is not a plain
  extension.
  """
  @spec extension(map()) :: String.t() | nil
  def extension(content) do
    value =
      (Map.get(content, :container_extension) || "mp4")
      |> to_string()
      |> String.trim()
      |> String.trim_leading(".")
      |> String.downcase()

    if Regex.match?(@extension, value), do: value
  end

  defp stream_url(provider, :movie, content, extension) do
    XtreamClient.movie_stream_url(
      provider.url,
      provider.username,
      provider.password,
      content.stream_id,
      extension
    )
  end

  defp stream_url(provider, :episode, content, extension) do
    XtreamClient.episode_stream_url(
      provider.url,
      provider.username,
      provider.password,
      content.episode_id,
      extension
    )
  end

  defp gindex?(%{gindex_path: path}) when is_binary(path) and path != "", do: true
  defp gindex?(_content), do: false
end
