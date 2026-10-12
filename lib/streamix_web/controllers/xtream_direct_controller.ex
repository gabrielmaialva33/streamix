defmodule StreamixWeb.XtreamDirectController do
  @moduledoc """
  Direct-client playback for progressive VOD of `direct_client_playback`
  providers: `/api/stream/vod/direct.<container>?token=…` (GET, HEAD,
  OPTIONS).

  This is the one owner-approved exception to "never hand an upstream URL to
  a browser". Such a provider's progressive CDN refuses this server's
  datacenter address but serves end users, so after the full movie/episode
  token authorization (`StreamixWeb.StreamToken.authorize_xtream_direct/2`)
  the client is redirected — `302`, `Cache-Control: no-store`,
  `Referrer-Policy: no-referrer` — to the final CDN URL. That URL was
  resolved server-side by walking the item's redirect chain without reading
  a body, is `https`, and never contains the account password (it may carry
  the username and a short-lived CDN token). The URL suffix names the
  container so every player picks a progressive engine; HLS items of the
  same provider are served by the HLS gateway instead.

  The response has no body and nothing here logs the URL.
  """

  use StreamixWeb, :controller

  import StreamixWeb.HlsResponse, only: [cors: 1]

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
    upstream_unavailable: :upstream_unavailable,
    upstream_timeout: :upstream_timeout
  }

  @container ~r/^[a-z0-9]{1,8}$/

  def options(conn, _params), do: conn |> cors() |> send_resp(204, "")

  def show(conn, %{"token" => token, "ext" => extension}) when is_binary(token) do
    with :ok <- progressive_container(extension),
         {:ok, playback} <-
           StreamToken.authorize_xtream_direct(token,
             bypass_subscription: ApiKeyAuth.valid_api_key?(conn)
           ) do
      conn
      |> cors()
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("location", playback.url)
      |> send_resp(302, "")
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, _params), do: error(conn, :missing_token)

  # A player sent to this route chose a progressive engine from its suffix.
  defp progressive_container("m3u8"), do: {:error, :stream_format_mismatch}

  defp progressive_container(extension) do
    if Regex.match?(@container, extension), do: :ok, else: {:error, :stream_format_mismatch}
  end

  defp error(conn, reason) do
    code = Map.get(@error_codes, reason, :stream_resolution_failed)

    conn
    |> cors()
    |> StreamErrors.halt(code)
  end
end
