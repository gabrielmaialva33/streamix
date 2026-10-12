defmodule Streamix.Hls.Gateway do
  @moduledoc """
  Serves one registered HLS resource on behalf of a session-owning gateway.

  A playlist — by its registered role, or because its body starts with
  `#EXTM3U` — is fetched without the client's `Range`, parsed, and rewritten so
  every reference becomes a gateway URL produced by the caller's
  `:resource_url` function; the references are registered through the
  caller's `:register` function first. Anything else is relayed as media: the
  client's single `Range` and method go upstream unchanged and the status,
  `Content-Range` and `Content-Length` come back.

  Upstream content types are advisory and frequently wrong (variant playlists
  served as `text/plain`, MPEG-TS segments as `application/javascript`), so
  they never decide how a body is treated. A media response carries its
  declared type only when that type is on a media allowlist, and
  `application/octet-stream` otherwise, so a browser never interprets
  upstream HTML or script. With `sniff_media: true`, a body that is visibly
  MPEG-TS (sync byte `0x47` every 188 bytes) is labelled `video/mp2t`.

  The session owners (`Streamix.Embedplay.Gateway` and
  `Streamix.Iptv.Streaming.XtreamHls`) keep authorization, leases and the
  registry; this module never stores anything.
  """

  alias Streamix.Hls.{Fetch, Playlist}

  @media_types ~w(video/mp2t video/mp4 audio/mp4 audio/aac audio/mpeg text/vtt application/octet-stream)
  @playlist_type "application/vnd.apple.mpegurl"
  @ts_packet 188

  @doc """
  Fetches `resource` (`%{url:, kind:}` plus optional `:headers`) and prepares
  the client response `%{status:, body:, headers:}`.

  Options:

    * `:register` — `fn [{url, kind}] -> {:ok, ids} | {:error, reason} end`
    * `:resource_url` — `fn id -> client_url end`
    * `:method`, `:range` — the client's method and single byte range
    * `:http_options` — Req options for the upstream requests
    * `:sniff_media` — label visible MPEG-TS bodies `video/mp2t`
    * `:playlist_timeout`, `:media_timeout` — total deadline (ms) of one
      upstream hop for a playlist or a media resource (default 15 s each)

  A `HEAD` on a playlist is answered without an upstream request.
  """
  def serve(%{url: url, kind: kind} = resource, opts) do
    if kind == :playlist and Keyword.get(opts, :method) == :head do
      {:ok, manifest_head()}
    else
      fetch_opts =
        if kind == :playlist,
          do: [timeout: Keyword.get(opts, :playlist_timeout)],
          else: [
            timeout: Keyword.get(opts, :media_timeout),
            range: Keyword.get(opts, :range),
            method: Keyword.get(opts, :method)
          ]

      fetch_opts =
        fetch_opts
        |> Enum.reject(&is_nil(elem(&1, 1)))
        |> Keyword.put(:http_options, Keyword.get(opts, :http_options, []))

      with {:ok, response} <- Fetch.fetch(url, Map.get(resource, :headers, []), fetch_opts) do
        respond(response, kind, opts)
      end
    end
  end

  @doc """
  Rewrites a playlist body fetched from `base_url`: registers its references
  through `register` and replaces each with `resource_url.(id)`.
  """
  def rewrite_playlist(body, base_url, register, resource_url) do
    with {:ok, template} <- playlist_template(body, base_url, register) do
      {:ok, render_template(template, resource_url)}
    end
  end

  @doc """
  Parses and registers a playlist body into a template: text and
  `{:id, resource_id}` nodes, plus the ordered resource ids of its media
  segments (`:segments`).

  A template names resources only by their opaque ids — never an upstream URL
  and never a client token — so a session may keep it and render it for every
  viewer with that viewer's own resource URLs (`render_template/2`).
  """
  def playlist_template(body, base_url, register) do
    with {:ok, nodes} <- Playlist.parse(body, base_url),
         resources = Enum.uniq(for {:resource, url, kind} <- nodes, do: {url, kind}),
         {:ok, ids} <- register.(resources) do
      mapping = Map.new(Enum.zip(resources, ids))

      # A reference on a line of its own (after a newline) is a URI line:
      # a variant or a segment. One inside a tag is an attribute (a key, a map,
      # a rendition). Media URI lines are the segments, in playback order.
      {nodes, {segments, _previous}} =
        Enum.map_reduce(nodes, {[], "\n"}, &template_node(&1, &2, mapping))

      {:ok, %{nodes: nodes, segments: Enum.reverse(segments)}}
    end
  end

  defp template_node({:resource, url, kind}, {segments, previous}, mapping) do
    id = Map.fetch!(mapping, {url, kind})
    segments = if previous == "\n" and kind == :media, do: [id | segments], else: segments
    {{:id, id}, {segments, :resource}}
  end

  defp template_node(text, {segments, _previous}, _mapping), do: {text, {segments, text}}

  @doc "Renders a playlist template with `resource_url.(id)` for every reference."
  def render_template(%{nodes: nodes}, resource_url) do
    nodes
    |> Enum.map(fn
      {:id, id} -> resource_url.(id)
      text -> text
    end)
    |> IO.iodata_to_binary()
  end

  @doc "The client response for a rendered playlist."
  def playlist_response(body),
    do: %{status: 200, body: body, headers: %{"content-type" => [@playlist_type]}}

  defp respond(response, kind, opts) do
    if kind == :playlist or Playlist.playlist?(response.body) do
      with {:ok, template} <-
             playlist_template(response.body, response.url, Keyword.fetch!(opts, :register)) do
        body = render_template(template, Keyword.fetch!(opts, :resource_url))
        {:ok, Map.put(playlist_response(body), :template, template)}
      end
    else
      type =
        if Keyword.get(opts, :sniff_media, false),
          do: media_type(response.headers, response.body),
          else: media_type(response.headers)

      headers = Map.put(response.headers, "content-type", [type])
      {:ok, %{status: response.status, body: response.body, headers: headers}}
    end
  end

  @doc """
  The client-facing media type for upstream `headers`: the declared type when
  it is on the media allowlist, `application/octet-stream` otherwise.
  """
  def media_type(headers) do
    declared =
      case headers |> Map.get("content-type", []) |> List.first() do
        type when is_binary(type) -> type |> String.split(";") |> hd() |> String.downcase()
        _ -> nil
      end

    if declared in @media_types, do: declared, else: "application/octet-stream"
  end

  @doc """
  Like `media_type/1`, but a body that is visibly MPEG-TS is labelled
  `video/mp2t` whatever the upstream declared.
  """
  def media_type(headers, body) do
    if mpeg_ts?(body), do: "video/mp2t", else: media_type(headers)
  end

  # A transport stream is a run of 188-byte packets that each start with the
  # sync byte. Checking the second packet too keeps a stray 0x47 (a "G") from
  # relabelling a text body.
  defp mpeg_ts?(<<0x47, _::binary>> = body) when byte_size(body) > @ts_packet,
    do: :binary.at(body, @ts_packet) == 0x47

  defp mpeg_ts?(_body), do: false

  @doc "The response to a `HEAD` on a playlist: the HLS type, no upstream request."
  def manifest_head do
    %{status: 200, body: "", headers: %{"content-type" => [@playlist_type]}}
  end

  @doc "Accepts no `Range` or one single byte range; refuses multi-range and junk."
  def valid_range(nil), do: :ok

  def valid_range(range) when is_binary(range) and byte_size(range) <= 80 do
    if Regex.match?(~r/^bytes=(?:\d+-\d*|-\d+)$/, range),
      do: :ok,
      else: {:error, :invalid_range}
  end

  def valid_range(_), do: {:error, :invalid_range}
end
