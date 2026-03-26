defmodule StreamixWeb.StreamController do
  @moduledoc """
  Controller for proxying IPTV streams with true streaming support using Mint.

  Proxies HTTP streams through HTTPS to avoid mixed content blocking.
  Uses Mint for low-level HTTP streaming without buffering.
  Follows redirects automatically (up to 5 hops).
  """
  use StreamixWeb, :controller

  require Logger

  @max_redirects 5

  alias StreamixWeb.StreamToken

  @doc """
  Handle OPTIONS preflight request for CORS.
  AVPlayer uses fetch() which sends preflight requests.
  """
  def options(conn, _params) do
    conn
    |> put_cors_headers()
    |> put_resp_header("access-control-max-age", "86400")
    |> send_resp(204, "")
  end

  @doc """
  Proxies a stream using a signed token (secure, recommended).
  The token is verified server-side and exchanged for the actual stream URL.
  Credentials are never exposed to the client.
  """
  def proxy(conn, %{"token" => token}) do
    case StreamToken.verify_and_get_url(token) do
      {:ok, url, content_type} ->
        # All content types redirect to nginx proxy which handles redirects,
        # Range headers, and CORS natively. For VOD we resolve the redirects
        # first so credentials never reach the browser. For live channels,
        # we send straight to nginx which follows redirects via @handle_redirect.
        Logger.info("Stream proxy: #{content_type} url=#{sanitize_url(url)}")

        case content_type do
          "channel" ->
            # Live: nginx handles redirects + streaming natively
            redirect_to_nginx_proxy(conn, url)

          _ ->
            # VOD: resolve redirects server-side to get final delivery URL
            resolve_and_redirect_to_proxy(conn, url, 0)
        end

      {:error, :token_expired} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Stream token expired"})

      {:error, :invalid_token} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid stream token"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Content not found"})

      {:error, :unauthorized} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Token not authorized for this content"})

      {:error, :unsafe_url} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "URL blocked by security policy"})
    end
  end

  def proxy(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing token parameter"})
  end

  # --- VOD: resolve redirects and send to nginx proxy for Range support ---

  defp resolve_and_redirect_to_proxy(conn, _url, redirect_count)
       when redirect_count > @max_redirects do
    Logger.error("Stream proxy: too many redirects resolving VOD URL")

    conn
    |> put_status(:bad_gateway)
    |> json(%{error: "Too many redirects"})
  end

  # VOD: resolve IPTV provider redirects, then redirect to nginx with final URL.
  # Follows redirects manually with Req (redirect: false) to track the final URL.
  defp resolve_and_redirect_to_proxy(conn, _url, redirect_count)
       when redirect_count > @max_redirects do
    Logger.error("Stream proxy: too many redirects resolving VOD URL")
    conn |> put_status(:bad_gateway) |> json(%{error: "Too many redirects"})
  end

  defp resolve_and_redirect_to_proxy(conn, url, redirect_count) do
    case Req.get(url,
           redirect: false,
           headers: [{"user-agent", "VLC/3.0.20 LibVLC/3.0.20"}],
           into: :self,
           receive_timeout: 5_000,
           connect_options: [timeout: 5_000]
         ) do
      {:ok, %Req.Response{status: status, headers: headers} = resp}
      when status in [301, 302, 303, 307, 308] ->
        Req.cancel_async_response(resp)

        case List.first(Map.get(headers, "location", [])) do
          nil ->
            conn |> put_status(:bad_gateway) |> json(%{error: "Missing redirect location"})

          location ->
            redirect_url =
              if String.starts_with?(location, "http") do
                location
              else
                URI.merge(url, location) |> URI.to_string()
              end

            Logger.info(
              "Stream proxy: VOD redirect #{redirect_count + 1} → #{sanitize_url(redirect_url)}"
            )

            resolve_and_redirect_to_proxy(conn, redirect_url, redirect_count + 1)
        end

      {:ok, %Req.Response{} = resp} ->
        # Final URL — got 200 or similar. Send browser to nginx proxy.
        Req.cancel_async_response(resp)

        proxy_base =
          Application.get_env(:streamix, :stream_proxy_url, "https://pannxs.mahina.cloud")

        final_proxy = "#{proxy_base}/proxy?url=#{URI.encode_www_form(url)}"
        Logger.info("Stream proxy: VOD resolved → #{sanitize_url(url)}")

        conn
        |> put_resp_header("access-control-allow-origin", "*")
        |> put_resp_header("cache-control", "no-cache, no-store")
        |> redirect(external: final_proxy)

      {:error, reason} ->
        Logger.error("Stream proxy: VOD resolve failed: #{inspect(reason)}")
        conn |> put_status(:bad_gateway) |> json(%{error: "Failed to resolve stream URL"})
    end
  end

  # Live channels: redirect to nginx proxy directly (nginx follows redirects natively)
  defp redirect_to_nginx_proxy(conn, url) do
    proxy_base = Application.get_env(:streamix, :stream_proxy_url, "https://pannxs.mahina.cloud")
    final_proxy = "#{proxy_base}/proxy?url=#{URI.encode_www_form(url)}"

    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("cache-control", "no-cache, no-store")
    |> redirect(external: final_proxy)
  end

  defp put_cors_headers(conn) do
    origin = get_cors_origin(conn)

    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-methods", "GET, HEAD, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "Range, Accept-Encoding")
    |> put_resp_header("access-control-allow-credentials", "true")
    |> put_resp_header(
      "access-control-expose-headers",
      "Content-Length, Content-Range, Accept-Ranges"
    )
  end

  defp get_cors_origin(conn) do
    origins = Application.get_env(:streamix, :cors, [])[:origins] || []

    case Plug.Conn.get_req_header(conn, "origin") do
      [origin] ->
        if origin_allowed?(origin, origins), do: origin, else: "null"

      _ ->
        "null"
    end
  end

  defp origin_allowed?(_origin, :all), do: true
  defp origin_allowed?(origin, origins) when is_list(origins), do: origin in origins
  defp origin_allowed?(_origin, _), do: false

  # Sanitize XUI URLs to strip credentials from log output.
  # Replaces /live/USERNAME/PASSWORD/, /movie/USERNAME/PASSWORD/,
  # and /series/USERNAME/PASSWORD/ with redacted placeholders.
  defp sanitize_url(url) do
    url
    |> String.replace(~r{/(live|movie|series)/[^/]+/[^/]+/}, "/\\1/[REDACTED]/[REDACTED]/")
  end
end
