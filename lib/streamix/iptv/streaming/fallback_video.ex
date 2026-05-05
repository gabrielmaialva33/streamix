defmodule Streamix.Iptv.Streaming.FallbackVideo do
  @moduledoc """
  Serves a short pre-rendered MP4 in place of a 4xx/5xx error page when
  the upstream proxy can't deliver the requested stream.

  Players that can't read JSON error bodies (most native AVPlayers, set-top
  boxes, mpegts.js) silently abort on a non-2xx status. Showing them a
  legible "Channel Unavailable" frame is a much better UX than a black
  screen with a console error.

  ## Categories

    * `:channel_unavailable` — upstream returned a terminal status (404, 410,
      etc.) for this specific stream
    * `:provider_unavailable` — chain resolution failed before we ever got
      a response (DNS, connection refused, TLS error)
    * `:account_expired` — upstream returned 401/403 (creds rejected)
    * `:stream_blocked` — upstream returned 451 / geo-block
    * `:rate_limited` — upstream returned 429 / 509

  Assets live in `priv/static/error_streams/<category>.mp4`. Re-render with:

      ffmpeg -f lavfi -i color=c=#0f1115:s=1280x720:d=8 \\
        -vf "drawtext=text='Channel Unavailable':fontsize=72:fontcolor=white:..." \\
        -c:v libx264 -profile:v baseline -pix_fmt yuv420p \\
        -movflags +faststart -t 8 -an channel_unavailable.mp4
  """

  alias Plug.Conn

  require Logger

  @categories ~w(
    channel_unavailable
    provider_unavailable
    account_expired
    stream_blocked
    rate_limited
  )a

  @type category :: unquote(Enum.reduce(@categories, &{:|, [], [&1, &2]}))

  @doc """
  Serves the pre-rendered MP4 for `category` on `conn`.

  No-op (returns conn unchanged) when the asset is missing — falls back to
  whatever the caller does with the bare `Conn`.
  """
  @spec serve(Conn.t(), category()) :: Conn.t()
  def serve(conn, category) when category in @categories do
    case asset_path(category) do
      {:ok, path} ->
        conn
        |> Conn.put_resp_header("content-type", "video/mp4")
        |> Conn.put_resp_header("cache-control", "no-cache, no-store")
        |> Conn.put_resp_header("x-streamix-fallback", Atom.to_string(category))
        |> put_cors_headers()
        |> Conn.send_file(200, path)

      :error ->
        Logger.warning("[FallbackVideo] missing asset for #{inspect(category)}")
        conn
    end
  end

  @doc """
  Maps a `VodProxy` failure reason to the closest fallback category.
  """
  @spec category_from_reason(term()) :: category()
  def category_from_reason({:unexpected_status, status}) when status in [401, 403],
    do: :account_expired

  def category_from_reason({:unexpected_status, 451}), do: :stream_blocked

  def category_from_reason({:unexpected_status, status}) when status in [429, 509],
    do: :rate_limited

  def category_from_reason({:unexpected_status, status}) when status in 400..499,
    do: :channel_unavailable

  def category_from_reason({:unexpected_status, _status}), do: :provider_unavailable
  def category_from_reason(:upstream_not_found), do: :channel_unavailable
  def category_from_reason(:upstream_timeout), do: :provider_unavailable
  def category_from_reason(:stream_resolution_failed), do: :provider_unavailable
  def category_from_reason(_), do: :provider_unavailable

  defp asset_path(category) do
    path =
      :streamix
      |> :code.priv_dir()
      |> Path.join("static/error_streams/#{category}.mp4")

    if File.regular?(path), do: {:ok, path}, else: :error
  end

  defp put_cors_headers(conn) do
    conn
    |> Conn.put_resp_header("access-control-allow-origin", "*")
    |> Conn.put_resp_header("access-control-allow-methods", "GET, HEAD, OPTIONS")
    |> Conn.put_resp_header("access-control-allow-headers", "Range, Accept-Encoding")
  end
end
