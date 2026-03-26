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
  # Timeout for receiving multiplexer chunks before considering the stream dead
  @mux_recv_timeout 30_000

  alias Streamix.Iptv.StreamMultiplexer
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
        # Check original method before Plug.Head converted HEAD to GET
        if conn.assigns[:original_method] == "HEAD" do
          head_request(conn, url, 0)
        else
          case content_type do
            "channel" ->
              # Live channels use the multiplexer for 1:N fan-out
              stream_key = :crypto.hash(:md5, url) |> Base.encode16(case: :lower)

              Logger.info(
                "Stream proxy: live channel via multiplexer, key=#{stream_key} url=#{sanitize_url(url)}"
              )

              stream_from_multiplexer(conn, stream_key, url)

            _vod ->
              # VOD content needs Range support for MP4 seeking (moov atom).
              # Resolve provider redirects server-side, then send browser to nginx
              # proxy with the final URL (no credentials, just delivery JWT).
              Logger.info("Stream proxy: VOD content (#{content_type}) url=#{sanitize_url(url)}")
              resolve_and_redirect_to_proxy(conn, url, 0)
          end
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

  defp resolve_and_redirect_to_proxy(conn, url, redirect_count) do
    uri = URI.parse(url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    port = uri.port || if(scheme == :https, do: 443, else: 80)
    path = build_request_path(uri)
    headers = build_upstream_headers(conn, uri.host)

    case connect_and_head_request(scheme, uri.host, port, path, headers) do
      {:ok, mint_conn, request_ref} ->
        case receive_headers(mint_conn, request_ref) do
          {:ok, _mint_conn, status, resp_headers, _data, _done} ->
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

          {:error, _mint_conn, reason} ->
            Logger.error("Stream proxy: VOD resolve failed: #{inspect(reason)}")
            conn |> put_status(:bad_gateway) |> json(%{error: "Failed to resolve stream URL"})
        end

      {:error, reason} ->
        Logger.error("Stream proxy: VOD resolve connect failed: #{inspect(reason)}")
        conn |> put_status(:bad_gateway) |> json(%{error: "Failed to resolve stream URL"})
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

  # --- Live channel streaming via StreamMultiplexer ---

  defp stream_from_multiplexer(conn, stream_key, url) do
    case StreamMultiplexer.subscribe(stream_key, url) do
      :ok ->
        conn =
          conn
          |> put_cors_headers()
          |> put_resp_content_type("video/mp2t")
          |> put_resp_header("cache-control", "no-cache, no-store")
          |> put_resp_header("x-accel-buffering", "no")
          |> send_chunked(200)

        mux_receive_loop(conn, stream_key)

      {:error, reason} ->
        Logger.error(
          "Stream proxy: multiplexer subscribe failed key=#{stream_key} reason=#{inspect(reason)}"
        )

        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to start live stream", reason: inspect(reason)})
    end
  end

  defp mux_receive_loop(conn, stream_key) do
    receive do
      {:stream_chunk, data} ->
        case chunk(conn, data) do
          {:ok, conn} ->
            mux_receive_loop(conn, stream_key)

          {:error, _reason} ->
            # Client disconnected
            Logger.info("Stream proxy: client disconnected from live stream key=#{stream_key}")
            StreamMultiplexer.unsubscribe(stream_key)
            conn
        end

      :stream_done ->
        Logger.info("Stream proxy: live stream ended key=#{stream_key}")
        StreamMultiplexer.unsubscribe(stream_key)
        conn

      {:stream_error, reason} ->
        Logger.error(
          "Stream proxy: live stream error key=#{stream_key} reason=#{inspect(reason)}"
        )

        StreamMultiplexer.unsubscribe(stream_key)
        conn
    after
      @mux_recv_timeout ->
        Logger.warning("Stream proxy: live stream timeout key=#{stream_key}")
        StreamMultiplexer.unsubscribe(stream_key)
        conn
    end
  end

  # Handle HEAD requests - return only headers, no body
  defp head_request(conn, _url, redirect_count) when redirect_count > @max_redirects do
    Logger.error("Stream proxy HEAD: too many redirects")

    conn
    |> put_status(:bad_gateway)
    |> json(%{error: "Too many redirects"})
  end

  defp head_request(conn, url, redirect_count) do
    uri = URI.parse(url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    port = uri.port || default_port(scheme)
    path = build_request_path(uri)
    headers = build_upstream_headers(conn, uri.host)

    Logger.info("Stream proxy HEAD: connecting to #{uri.host}:#{port}#{sanitize_url(path)}")

    case connect_and_head_request(scheme, uri.host, port, path, headers) do
      {:ok, mint_conn, request_ref} ->
        handle_head_response(conn, mint_conn, request_ref, url, redirect_count)

      {:error, reason} ->
        Logger.error("Stream proxy HEAD connection error: #{inspect(reason)}")

        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to connect to stream", reason: inspect(reason)})
    end
  end

  defp connect_and_head_request(scheme, host, port, path, headers) do
    transport_opts =
      case scheme do
        :https -> [cacerts: :public_key.cacerts_get(), timeout: @connect_timeout]
        :http -> [timeout: @connect_timeout]
      end

    case Mint.HTTP.connect(scheme, host, port, transport_opts: transport_opts) do
      {:ok, mint_conn} ->
        case Mint.HTTP.request(mint_conn, "HEAD", path, headers, nil) do
          {:ok, mint_conn, request_ref} ->
            {:ok, mint_conn, request_ref}

          {:error, mint_conn, reason} ->
            Mint.HTTP.close(mint_conn)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_head_response(conn, mint_conn, request_ref, original_url, redirect_count) do
    case receive_headers(mint_conn, request_ref) do
      {:ok, _mint_conn, status, headers, _initial_data, _body_complete?} ->
        Mint.HTTP.close(mint_conn)
        process_head_response(conn, status, headers, original_url, redirect_count)

      {:error, _mint_conn, reason} ->
        Logger.error("Stream proxy HEAD header error: #{inspect(reason)}")

        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to read stream headers", reason: inspect(reason)})
    end
  end

  defp process_head_response(conn, status, headers, original_url, redirect_count)
       when status in [301, 302, 303, 307, 308] do
    # Handle redirects
    case get_header(headers, "location") do
      nil ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Redirect without Location header"})

      location ->
        redirect_url = resolve_url(original_url, location)

        case UrlValidator.validate_url(redirect_url) do
          :ok ->
            head_request(conn, redirect_url, redirect_count + 1)

          {:error, :unsafe_url} ->
            Logger.warning(
              "Stream proxy HEAD: blocked redirect to unsafe URL #{sanitize_url(redirect_url)}"
            )

            conn
            |> put_status(:forbidden)
            |> json(%{error: "Redirect blocked by security policy"})
        end
    end
  end

  defp process_head_response(conn, status, headers, _original_url, _redirect_count) do
    # Return headers only (no body for HEAD)
    content_length = get_header(headers, "content-length")
    content_type = get_header(headers, "content-type")

    conn
    |> put_cors_headers()
    |> put_resp_header("accept-ranges", "bytes")
    |> maybe_put_header("content-length", content_length)
    |> maybe_put_header("content-type", content_type)
    |> send_resp(normalize_status(status), "")
  end

  defp default_port(:https), do: 443
  defp default_port(:http), do: 80

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

  defp normalize_status(206), do: 206
  defp normalize_status(_), do: 200

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

  # Helper to add optional header without deep nesting
  defp maybe_put_header(conn, _name, nil), do: conn
  defp maybe_put_header(conn, name, value), do: put_resp_header(conn, name, value)

  # Sanitize XUI URLs to strip credentials from log output.
  # Replaces /live/USERNAME/PASSWORD/, /movie/USERNAME/PASSWORD/,
  # and /series/USERNAME/PASSWORD/ with redacted placeholders.
  defp sanitize_url(url) do
    url
    |> String.replace(~r{/(live|movie|series)/[^/]+/[^/]+/}, "/\\1/[REDACTED]/[REDACTED]/")
  end
end
