defmodule Streamix.Iptv.Streaming.XtreamDelivery do
  @moduledoc """
  Decides how an Xtream VOD item (movie or episode) reaches a player.

    * `{:hls, "m3u8"}` — the item's `container_extension` is `m3u8`: its
      Xtream URL answers an HLS master playlist, so it is served by the HLS
      gateway (`Streamix.Iptv.Streaming.XtreamHls`) under a `.m3u8` URL.
    * `:proxy` — everything else keeps the progressive token proxy.

  Every client picks its playback engine from the URL suffix, so URL minting,
  the token proxy's redirect and the gateway's own authorization all ask
  this one function and never disagree. Only `:xtream` providers qualify;
  GIndex-backed rows keep their own route.
  """

  @extension ~r/^[a-z0-9]{1,8}$/

  @type mode :: {:hls, String.t()} | :proxy

  @spec mode(map() | nil, map()) :: mode()
  def mode(%{provider_type: type}, content)
      when type in [:xtream, "xtream"] and is_map(content) do
    cond do
      gindex?(content) -> :proxy
      extension(content) == "m3u8" -> {:hls, "m3u8"}
      true -> :proxy
    end
  end

  def mode(_provider, _content), do: :proxy

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

  defp gindex?(%{gindex_path: path}) when is_binary(path) and path != "", do: true
  defp gindex?(_content), do: false
end
