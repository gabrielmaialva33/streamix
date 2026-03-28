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

        # ALL content types resolve redirects server-side to strip credentials.
        # The final delivery URL (JWT only, no credentials) goes to nginx proxy.
        resolve_and_redirect_to_proxy(conn, url, 0)

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

  defp resolve_and_redirect_to_proxy(conn, url, _redirect_count) do
    # Follow redirects step by step to track the final URL.
    # Use redirect: false and follow manually so we know each hop.
    case resolve_final_url(url, 0) do
      {:ok, final_url} ->
        # Security: NEVER send original provider URL (has credentials) to the browser.
        # Only send the final delivery URL (has only a short-lived JWT token).
        if credentials_in_url?(final_url) do
          Logger.error("Stream proxy: BLOCKED — final URL still contains credentials")
          conn |> put_status(:bad_gateway) |> json(%{error: "Stream resolution failed"})
        else
          proxy_base =
            Application.get_env(:streamix, :stream_proxy_url, "https://pannxs.mahina.cloud")

          final_proxy = "#{proxy_base}/proxy?url=#{URI.encode_www_form(final_url)}"
          Logger.info("Stream proxy: VOD resolved → #{sanitize_url(final_url)}")

          conn
          |> put_resp_header("access-control-allow-origin", "*")
          |> put_resp_header("cache-control", "no-cache, no-store")
          |> redirect(external: final_proxy)
        end

      {:error, reason} ->
        Logger.error("Stream proxy: VOD resolve failed: #{inspect(reason)}")
        conn |> put_status(:bad_gateway) |> json(%{error: "Failed to resolve stream URL"})
    end
  end

  # Resolve all redirects step by step using HEAD-then-GET fallback.
  # Returns the final URL after all redirects are followed.
  defp resolve_final_url(_url, count) when count > @max_redirects do
    {:error, :too_many_redirects}
  end

  defp resolve_final_url(url, count) do
    case Req.get(url,
           redirect: false,
           headers: [{"user-agent", "VLC/3.0.20 LibVLC/3.0.20"}],
           decode_body: false,
           receive_timeout: 5_000,
           connect_options: [timeout: 5_000],
           # Only read up to 1KB (redirect responses are tiny HTML)
           max_body: 1_024
         ) do
      {:ok, %{status: status, headers: headers}} when status in [301, 302, 303, 307, 308] ->
        follow_resolved_redirect(url, headers, count)

      {:ok, %{status: status}} when status in 200..299 ->
        {:ok, url}

      {:ok, %{status: status}} ->
        Logger.error(
          "Stream proxy: resolve got unexpected status #{status} for #{sanitize_url(url)}"
        )

        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp follow_resolved_redirect(url, headers, count) do
    case List.first(Map.get(headers, "location", [])) do
      nil ->
        {:error, :missing_location}

      location ->
        next_url = resolve_redirect_location(url, location)
        Logger.info("Stream proxy: resolve redirect #{count + 1} → #{sanitize_url(next_url)}")
        resolve_final_url(next_url, count + 1)
    end
  end

  defp resolve_redirect_location(url, location) do
    if String.starts_with?(location, "http") do
      location
    else
      url
      |> URI.merge(location)
      |> URI.to_string()
    end
  end

  # Check if URL contains IPTV provider credentials
  defp credentials_in_url?(url) do
    uri = URI.parse(url)
    # Provider URLs have pattern: /live|movie|series/USERNAME/PASSWORD/...
    case uri.path do
      nil -> false
      path -> Regex.match?(~r{/(live|movie|series)/[^/]+/[^/]+/}, path)
    end
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
