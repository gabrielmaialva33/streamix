defmodule StreamixWeb.StreamController do
  @moduledoc """
  Controller for proxying IPTV streams with true streaming support using Mint.

  Proxies HTTP streams through HTTPS to avoid mixed content blocking.
  Uses Mint for low-level HTTP streaming without buffering.
  Follows redirects automatically (up to 5 hops).
  """
  use StreamixWeb, :controller

  require Logger

  @connect_timeout 10_000
  @recv_timeout 30_000
  @max_redirects 5

  alias StreamixWeb.StreamToken
  alias StreamixWeb.UrlValidator

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

  # VOD: resolve IPTV provider redirects, then redirect to nginx with final URL
  defp resolve_and_redirect_to_proxy(conn, url, redirect_count) do
    uri = URI.parse(url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    port = uri.port || if(scheme == :https, do: 443, else: 80)
    path = build_request_path(uri)
    headers = build_upstream_headers(conn, uri.host)

    # Use GET (not HEAD) because IPTV providers only redirect GET requests
    case connect_and_get_headers(scheme, uri.host, port, path, headers) do
      {:ok, mint_conn, status, resp_headers} ->
        # Close connection immediately — we only needed the status + headers
        Mint.HTTP.close(mint_conn)

        if status in [301, 302, 303, 307, 308] do
          handle_vod_redirect(conn, url, resp_headers, redirect_count)
        else
          # Final URL reached — redirect browser to nginx proxy
          proxy_base =
            Application.get_env(:streamix, :stream_proxy_url, "https://pannxs.mahina.cloud")

          final_proxy = "#{proxy_base}/proxy?url=#{URI.encode_www_form(url)}"
          Logger.info("Stream proxy: VOD resolved, redirecting to nginx proxy")

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

  # Live channels: redirect to nginx proxy directly (nginx follows redirects natively)
  defp redirect_to_nginx_proxy(conn, url) do
    proxy_base = Application.get_env(:streamix, :stream_proxy_url, "https://pannxs.mahina.cloud")
    final_proxy = "#{proxy_base}/proxy?url=#{URI.encode_www_form(url)}"

    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("cache-control", "no-cache, no-store")
    |> redirect(external: final_proxy)
  end

  # GET request that only reads status + headers, then returns (ignoring body)
  defp connect_and_get_headers(scheme, host, port, path, headers) do
    with {:ok, mint_conn} <- Mint.HTTP.connect(scheme, host, port, timeout: @connect_timeout),
         {:ok, mint_conn, request_ref} <- Mint.HTTP.request(mint_conn, "GET", path, headers, nil) do
      case receive_headers(mint_conn, request_ref) do
        {:ok, mint_conn, status, resp_headers, _data, _done} ->
          {:ok, mint_conn, status, resp_headers}

        {:error, _mint_conn, reason} ->
          {:error, reason}
      end
    end
  end

  defp handle_vod_redirect(conn, original_url, headers, redirect_count) do
    case get_header(headers, "location") do
      nil ->
        conn |> put_status(:bad_gateway) |> json(%{error: "Missing redirect location"})

      location ->
        redirect_url = resolve_url(original_url, location)

        case UrlValidator.validate_url(redirect_url) do
          :ok ->
            Logger.info(
              "Stream proxy: VOD resolve redirect #{redirect_count + 1} to #{sanitize_url(redirect_url)}"
            )

            resolve_and_redirect_to_proxy(conn, redirect_url, redirect_count + 1)

          {:error, :unsafe_url} ->
            conn |> put_status(:forbidden) |> json(%{error: "Blocked redirect to unsafe URL"})
        end
    end
  end

  defp build_request_path(uri) do
    path = uri.path || "/"
    if uri.query, do: "#{path}?#{uri.query}", else: path
  end

  defp build_upstream_headers(conn, host) do
    headers = [
      {"host", host},
      {"user-agent", "Streamix/1.0"},
      {"accept", "*/*"},
      {"connection", "keep-alive"}
    ]

    # Forward Range header if present (for seeking)
    case get_req_header(conn, "range") do
      [range] ->
        Logger.info("Forwarding Range header: #{range}")
        [{"range", range} | headers]

      _ ->
        Logger.debug("No Range header in request")
        headers
    end
  end

  defp resolve_url(base_url, location) do
    if String.starts_with?(location, "http://") or String.starts_with?(location, "https://") do
      location
    else
      base_uri = URI.parse(base_url)
      URI.merge(base_uri, location) |> URI.to_string()
    end
  end

  defp get_header(headers, name) do
    name_lower = String.downcase(name)

    case Enum.find(headers, fn {k, _v} -> String.downcase(k) == name_lower end) do
      {_, value} -> value
      nil -> nil
    end
  end

  # Returns {:ok, mint_conn, status, headers, initial_data, body_complete?} or {:error, mint_conn, reason}
  # initial_data is any data received while reading headers (needed for buffered responses)
  # body_complete? is true if the response is already complete (all data received)
  defp receive_headers(mint_conn, request_ref) do
    receive_headers_loop(mint_conn, request_ref, nil, [], <<>>)
  end

  defp receive_headers_loop(mint_conn, request_ref, status, headers, initial_data) do
    receive do
      message ->
        case Mint.HTTP.stream(mint_conn, message) do
          :unknown ->
            receive_headers_loop(mint_conn, request_ref, status, headers, initial_data)

          {:ok, mint_conn, responses} ->
            case process_header_responses(responses, request_ref, status, headers, initial_data) do
              {:continue, new_status, new_headers, new_data} ->
                receive_headers_loop(mint_conn, request_ref, new_status, new_headers, new_data)

              {:done, final_status, final_headers, final_data} ->
                # Response is complete - no more data to receive
                {:ok, mint_conn, final_status, final_headers, final_data, true}

              {:error, reason} ->
                {:error, mint_conn, reason}
            end

          {:error, mint_conn, reason, _responses} ->
            {:error, mint_conn, reason}
        end
    after
      @recv_timeout ->
        # Timeout while waiting for headers, but we might have partial headers with data
        # Return what we have if we got status and headers
        if status && headers != [] do
          {:ok, mint_conn, status, headers, initial_data, false}
        else
          {:error, mint_conn, :timeout}
        end
    end
  end

  defp process_header_responses([], _request_ref, status, headers, data) do
    {:continue, status, headers, data}
  end

  defp process_header_responses([response | rest], request_ref, status, headers, data) do
    case response do
      {:status, ^request_ref, new_status} ->
        process_header_responses(rest, request_ref, new_status, headers, data)

      {:headers, ^request_ref, new_headers} ->
        all_headers = headers ++ new_headers
        process_header_responses(rest, request_ref, status, all_headers, data)

      {:data, ^request_ref, new_data} ->
        # Accumulate data while processing remaining responses
        process_header_responses(rest, request_ref, status, headers, data <> new_data)

      {:done, ^request_ref} ->
        {:done, status, headers, data}

      {:error, ^request_ref, reason} ->
        {:error, reason}

      _ ->
        process_header_responses(rest, request_ref, status, headers, data)
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
