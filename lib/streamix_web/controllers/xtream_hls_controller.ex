defmodule StreamixWeb.XtreamHlsController do
  @moduledoc """
  HLS gateway routes for Xtream content delivered as HLS: movies and episodes
  stored as `m3u8` or probed as HLS, and live channels probed as HLS.

  | Route | Serves |
  | --- | --- |
  | `/api/stream/hls/master.m3u8?token=…` | the rewritten master playlist (a one-variant master for a live media playlist) |
  | `/api/stream/hls/:session_id/:resource_id?token=…` | variants, renditions, live playlist refreshes, keys, segments |

  Both routes authorize the signed movie/episode/channel token on every
  request (`StreamixWeb.StreamToken.authorize_xtream_hls/2`): resource
  requests are authorized with the original token, and a resource is served
  only from a session opened for that same item. A `HEAD` on the master
  authorizes and advertises the HLS type without an upstream request.

  `edge=1` marks a request that arrived through the browser stream proxy
  (`source.mahina.fun`); the rewritten playlist then wraps each reference in
  that proxy so the player stays behind it. Without it references are
  root-relative to this origin.

  The upstream Xtream URL embeds the account credentials. It goes from the
  token resolver straight to `Streamix.Playback`, and is never written into a
  response or a log line.
  """

  use StreamixWeb, :controller

  import StreamixWeb.HlsResponse

  require Logger

  alias Streamix.Playback
  alias StreamixWeb.Catalog.StreamUrls
  alias StreamixWeb.Plugs.ApiKeyAuth
  alias StreamixWeb.StreamErrors
  alias StreamixWeb.StreamToken

  @error_codes %{
    missing_token: :missing_token,
    invalid_token: :invalid_token,
    token_expired: :token_expired,
    unauthorized: :token_unauthorized,
    subscription_required: :subscription_required,
    not_found: :content_not_found,
    provider_disabled: :provider_disabled,
    provider_degraded: :provider_degraded,
    stream_format_mismatch: :stream_format_mismatch,
    provider_capacity_exhausted: :provider_capacity_exhausted,
    upstream_not_found: :upstream_not_found,
    resource_not_found: :resource_not_found,
    invalid_range: :invalid_range,
    playback_restart_required: :playback_restart_required,
    unsafe_url: :unsafe_url,
    upstream_unavailable: :upstream_unavailable,
    response_too_large: :upstream_unavailable,
    upstream_timeout: :upstream_timeout,
    not_a_stream: :not_a_stream
  }

  def options(conn, _params), do: conn |> cors() |> send_resp(204, "")

  def master(conn, %{"token" => token} = params) when is_binary(token) do
    case authorize(conn, token, stage: :start) do
      {:ok, playback} ->
        if head_request?(conn) do
          conn
          |> cors()
          |> put_resp_content_type("application/vnd.apple.mpegurl")
          |> send_resp(200, "")
        else
          open_and_serve(conn, playback, token, edge?(params))
        end

      {:error, reason} ->
        error(conn, reason)
    end
  end

  def master(conn, _params), do: error(conn, :missing_token)

  def resource(conn, %{"token" => token, "session_id" => sid, "resource_id" => rid} = params)
      when is_binary(token) do
    case authorize(conn, token, stage: :resource) do
      {:ok, playback} -> serve(conn, sid, rid, playback, token, edge?(params))
      {:error, reason} -> error(conn, reason)
    end
  end

  def resource(conn, _params), do: error(conn, :missing_token)

  defp authorize(conn, token, opts) do
    StreamToken.authorize_xtream_hls(
      token,
      Keyword.put(opts, :bypass_subscription, ApiKeyAuth.valid_api_key?(conn))
    )
  end

  defp open_and_serve(conn, playback, token, edge?) do
    with {:ok, session} <-
           Playback.open_xtream_hls(playback.content, playback.provider_id, playback.url),
         {:ok, response} <-
           Playback.fetch_xtream_hls_master(
             session.session_id,
             session.resource_id,
             playback.content,
             fetch_options(conn, token, edge?)
           ) do
      send_gateway_response(conn, response)
    else
      {:error, reason} ->
        log_master_failure(playback, reason)
        error(conn, master_error(reason))
    end
  end

  defp serve(conn, sid, rid, playback, token, edge?) do
    case Playback.fetch_xtream_hls_resource(
           sid,
           rid,
           playback.content,
           fetch_options(conn, token, edge?)
         ) do
      {:ok, response} -> send_gateway_response(conn, response)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp fetch_options(conn, token, edge?) do
    [
      method: method(conn),
      range: range(conn),
      resource_url: fn session_id, resource_id ->
        StreamUrls.hls_resource_url(session_id, resource_id, token, edge?)
      end
    ]
  end

  # Each master request fetches the Xtream URL afresh, so a 401/403/410 there
  # is the provider refusing the account, not a stale session to restart.
  defp master_error(:playback_restart_required), do: :upstream_unavailable
  defp master_error(reason), do: reason

  defp log_master_failure(%{content: {type, id}, provider_id: provider_id}, reason) do
    Logger.warning(
      "[XtreamHls] master unavailable content=#{Streamix.SafeLog.content_ref({type, id})} " <>
        "provider=#{provider_id} " <>
        "reason=#{inspect(reason)}"
    )
  end

  defp edge?(params), do: Map.get(params, "edge") == "1"

  defp error(conn, reason) do
    code = Map.get(@error_codes, reason, :stream_resolution_failed)

    conn
    |> cors()
    |> StreamErrors.halt(code)
  end
end
