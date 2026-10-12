defmodule Streamix.Iptv.Streaming.XtreamHls do
  @moduledoc """
  HLS gateway for Xtream VOD whose `container_extension` is `m3u8`.

  Such an item is not one byte-range file: its Xtream URL
  (`/movie/<user>/<pass>/<id>.m3u8`, `/series/…` for episodes) redirects to a
  master playlist whose variants, audio renditions and segments usually live
  on other hosts. Proxying it as a single file — the progressive token proxy —
  can only time out. Instead this module opens a session whose registry root
  is that URL and serves every playlist, key and segment through the shared
  `Streamix.Hls.Gateway`: playlists are rewritten so each reference becomes an
  opaque Streamix resource URL, and media is relayed under a safe type.

  The source is known up front, so there is no resolver and no health
  monitor: opening a session just registers the URL. Upstream MIME types are
  ignored for classification (measured: variants as `text/plain`, MPEG-TS
  segments as `application/javascript`); the registered role or an `#EXTM3U`
  body decides, and a visibly MPEG-TS body is labelled `video/mp2t`.

  Requests use the provider-facing User-Agent, validate every redirect hop
  against SSRF and run under a per-provider fetch lease (see
  `Streamix.Iptv.Streaming.XtreamHls.Sessions`). The Xtream URL embeds the
  account password: it never leaves this process and is never logged.
  """

  alias Streamix.Hls.Gateway
  alias Streamix.Iptv.Streaming.UpstreamPolicy
  alias Streamix.Iptv.Streaming.XtreamHls.Sessions

  @type content :: Sessions.content()

  @doc """
  Opens (or reuses) the playback session for `content`, rooted at its Xtream
  playlist `url`. Returns the opaque session and root resource identifiers.
  """
  @spec open(content(), integer(), String.t()) ::
          {:ok, %{session_id: String.t(), resource_id: String.t()}} | {:error, atom()}
  def open(content, provider_id, url) when is_binary(url),
    do: Sessions.open(content, provider_id, url)

  @doc """
  Fetches one registered resource of a session opened for `content`.

  Options: `:method` (`:get`/`:head`), `:range` (one byte range) and
  `:resource_url` (`fn session_id, resource_id -> client_url end`, used for
  every reference of a rewritten playlist).

  An upstream 401/403/410 invalidates the whole session and returns
  `{:error, :playback_restart_required}`; the next master request opens a
  fresh one.
  """
  def fetch_resource(session_id, resource_id, content, opts \\ []) do
    with :ok <- Gateway.valid_range(Keyword.get(opts, :range)),
         {:ok, resource, provider_id} <- Sessions.resource(session_id, resource_id, content),
         {:ok, lease} <- Sessions.acquire(provider_id) do
      try do
        resource
        |> Map.put(:headers, [{"user-agent", UpstreamPolicy.user_agent()}])
        |> Gateway.serve(serve_options(session_id, content, opts))
        |> invalidate_on_restart(session_id)
      after
        Sessions.release(lease)
      end
    end
  end

  @doc "Drops a session and its resource graph."
  defdelegate invalidate(session_id), to: Sessions

  defp serve_options(session_id, content, opts) do
    resource_url = Keyword.fetch!(opts, :resource_url)

    [
      method: Keyword.get(opts, :method),
      range: Keyword.get(opts, :range),
      http_options: Sessions.config(:http_options, []),
      sniff_media: true,
      register: &Sessions.register(session_id, content, &1),
      resource_url: &resource_url.(session_id, &1)
    ]
  end

  defp invalidate_on_restart({:error, :playback_restart_required} = error, session_id) do
    Sessions.invalidate(session_id)
    error
  end

  defp invalidate_on_restart(result, _session_id), do: result
end
