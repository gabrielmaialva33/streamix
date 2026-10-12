defmodule StreamixWeb.PlayerComponents.Metadata do
  @moduledoc false

  @fourk_hevc_pattern ~r/(2160p|\b4k\b|uhd|hevc|x265|h265|hvc1|hev1)/i

  # Streamix's own gateways are already CORS-safe origins. Wrapping the HLS
  # gateway's master in the stream proxy without `edge=1` would leave its
  # root-relative playlist references resolving against the proxy host, and
  # the direct-client route must never be fetched from the proxy: its egress
  # is an address the progressive CDN refuses, and it would log the CDN URL.
  @own_stream_routes [
    "/api/stream/proxy?token=",
    "/api/stream/torrent/",
    "/api/stream/hls/",
    "/api/stream/vod/direct."
  ]

  @spec proxy_url(String.t() | nil, atom()) :: String.t() | nil
  def proxy_url(stream_url, _content_type) when is_binary(stream_url) do
    if String.contains?(stream_url, @own_stream_routes) do
      stream_url
    else
      proxy_base =
        Application.get_env(:streamix, :stream_proxy_url, "https://source.mahina.fun")

      "#{proxy_base}/proxy?url=#{URI.encode_www_form(stream_url)}"
    end
  end

  def proxy_url(_stream_url, _content_type), do: nil

  @doc """
  The engine hint handed to the player for `stream_url`.

  A minted gateway URL names its own format and wins: an HLS gateway URL is
  HLS even for a live channel (whose default hint is `ts`) or a movie whose
  catalogue extension says `mp4` but whose probe found HLS, and a
  direct-client URL names the container the redirect leads to. Any other URL
  (the token proxies carry no extension) falls back to `stream_type_hint/3`.
  """
  @spec stream_type(String.t() | nil, atom(), map(), atom() | String.t()) :: String.t() | nil
  def stream_type(stream_url, content_type, content, source_type) do
    url_stream_type(stream_url) || stream_type_hint(content_type, content, source_type)
  end

  defp url_stream_type(url) when is_binary(url) do
    cond do
      String.contains?(url, "/api/stream/hls/") ->
        "m3u8"

      match = Regex.run(~r"/api/stream/vod/direct\.([a-z0-9]{1,8})\?", url) ->
        List.last(match)

      true ->
        nil
    end
  end

  defp url_stream_type(_url), do: nil

  @spec stream_type_hint(atom(), map(), atom() | String.t()) :: String.t() | nil
  def stream_type_hint(content_type, _content, _source_type)
      when content_type in [:live, :live_channel],
      do: "ts"

  def stream_type_hint(:torrent, _content, _source_type), do: "mp4"

  def stream_type_hint(_content_type, content, source_type)
      when source_type in [:gindex, "gindex"] do
    extension_from_path(Map.get(content, :gindex_path)) ||
      extension_from_path(Map.get(content, :container_extension)) ||
      "mkv"
  end

  def stream_type_hint(content_type, content, _source_type)
      when content_type in [:movie, :episode] do
    extension_from_path(Map.get(content, :container_extension)) || "mp4"
  end

  def stream_type_hint(_content_type, _content, _source_type), do: nil

  @spec title(map(), atom()) :: String.t() | nil
  def title(content, type) when type in [:live, :live_channel] do
    Map.get(content, :name)
  end

  def title(content, type) when type in [:movie, :gindex, :torrent] do
    Map.get(content, :title) || Map.get(content, :name)
  end

  def title(content, :episode) do
    Map.get(content, :title) || "Episódio #{Map.get(content, :episode_num, "")}"
  end

  def title(content, :gindex_episode) do
    Map.get(content, :title) || Map.get(content, :name) ||
      "Episódio #{Map.get(content, :episode_num, "")}"
  end

  @spec subtitle(map(), atom()) :: String.t()
  def subtitle(content, type) when type in [:episode, :gindex_episode] do
    series_name =
      Map.get(content, :series_name) || direct_series_name(content) || season_series_name(content)

    [series_name, episode_subtitle(content)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" - ")
  end

  def subtitle(_content, type) when type in [:live, :live_channel], do: "Ao vivo"
  def subtitle(_content, _type), do: "Streamix"

  @spec episode_subtitle(map()) :: String.t()
  def episode_subtitle(content) do
    season_num = Map.get(content, :season_number) || season_number(content) || "?"
    episode_num = Map.get(content, :episode_num, "?")
    "T#{season_num}:E#{episode_num}"
  end

  @spec uhd_hevc?(map()) :: boolean()
  def uhd_hevc?(content) when is_map(content) do
    haystack =
      content
      |> Map.take([:gindex_path, :title, :name])
      |> Map.values()
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    haystack != "" and Regex.match?(@fourk_hevc_pattern, haystack)
  end

  defp extension_from_path(value) when is_binary(value) and value != "" do
    decoded = URI.decode(value)

    case Path.extname(decoded) do
      "" -> bare_extension(decoded)
      extension -> extension |> String.trim_leading(".") |> String.downcase()
    end
  end

  defp extension_from_path(_value), do: nil

  defp bare_extension(value) do
    if String.match?(value, ~r/^[[:alnum:]]{2,8}$/u), do: String.downcase(value)
  end

  defp direct_series_name(%{series: %{name: name}}) when is_binary(name), do: name
  defp direct_series_name(_content), do: nil

  defp season_series_name(%{season: %{series: %{name: name}}}) when is_binary(name), do: name
  defp season_series_name(_content), do: nil

  defp season_number(%{season: %{season_number: number}}), do: number
  defp season_number(_content), do: nil
end
