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
      {:ok, url} ->
        # Check original method before Plug.Head converted HEAD to GET
        if conn.assigns[:original_method] == "HEAD" do
          head_request(conn, url, 0)
        else
          stream_url(conn, url, 0)
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
    end
  end

  def proxy(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing token parameter"})
  end

  defp stream_url(conn, _url, redirect_count) when redirect_count > @max_redirects do
    Logger.error("Stream proxy: too many redirects")

    conn
    |> put_status(:bad_gateway)
    |> json(%{error: "Too many redirects"})
  end

  defp stream_url(conn, url, redirect_count) do
    uri = URI.parse(url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    port = uri.port || default_port(scheme)
    path = build_request_path(uri)
    headers = build_upstream_headers(conn, uri.host)

    Logger.info("Stream proxy: connecting to #{uri.host}:#{port}#{path}")

    case connect_and_request(scheme, uri.host, port, path, headers) do
      {:ok, mint_conn, request_ref} ->
        handle_response(conn, mint_conn, request_ref, url, redirect_count)

      {:error, reason} ->
        Logger.error("Stream proxy connection error: #{inspect(reason)}")

        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to connect to stream", reason: inspect(reason)})
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

    Logger.info("Stream proxy HEAD: connecting to #{uri.host}:#{port}#{path}")

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

        if status in [301, 302, 303, 307, 308] do
          # Handle redirects
          case get_header(headers, "location") do
            nil ->
              conn
              |> put_status(:bad_gateway)
              |> json(%{error: "Redirect without Location header"})

            location ->
              redirect_url = resolve_url(original_url, location)
              head_request(conn, redirect_url, redirect_count + 1)
          end
        else
          # Return headers only (no body for HEAD)
          content_length = get_header(headers, "content-length")
          content_type = get_header(headers, "content-type")

          conn =
            conn
            |> put_cors_headers()
            |> put_resp_header("accept-ranges", "bytes")

          conn = if content_length, do: put_resp_header(conn, "content-length", content_length), else: conn
          conn = if content_type, do: put_resp_header(conn, "content-type", content_type), else: conn

          send_resp(conn, normalize_status(status), "")
        end

      {:error, _mint_conn, reason} ->
        Logger.error("Stream proxy HEAD header error: #{inspect(reason)}")

        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to read stream headers", reason: inspect(reason)})
    end
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

  defp connect_and_request(scheme, host, port, path, headers) do
    transport_opts =
      case scheme do
        :https -> [cacerts: :public_key.cacerts_get(), timeout: @connect_timeout]
        :http -> [timeout: @connect_timeout]
      end

    case Mint.HTTP.connect(scheme, host, port, transport_opts: transport_opts) do
      {:ok, mint_conn} ->
        case Mint.HTTP.request(mint_conn, "GET", path, headers, nil) do
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

  defp handle_response(conn, mint_conn, request_ref, original_url, redirect_count) do
    case receive_headers(mint_conn, request_ref) do
      {:ok, mint_conn, status, headers, initial_data, body_complete?} ->
        if status in [301, 302, 303, 307, 308] do
          # Handle redirects
          Mint.HTTP.close(mint_conn)
          handle_redirect(conn, headers, original_url, redirect_count)
        else
          # Normal response - stream it (pass initial_data that was received with headers)
          stream_response(conn, mint_conn, request_ref, status, headers, initial_data, body_complete?)
        end

      {:error, _mint_conn, reason} ->
        Logger.error("Stream proxy header error: #{inspect(reason)}")

        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to read stream headers", reason: inspect(reason)})
    end
  end

  defp handle_redirect(conn, headers, original_url, redirect_count) do
    case get_header(headers, "location") do
      nil ->
        Logger.error("Stream proxy: redirect without Location header")

        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Redirect without Location header"})

      location ->
        # Resolve relative URLs
        redirect_url = resolve_url(original_url, location)
        Logger.info("Stream proxy: following redirect to #{redirect_url}")
        stream_url(conn, redirect_url, redirect_count + 1)
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

  defp stream_response(conn, mint_conn, request_ref, status, headers, initial_data, body_complete?) do
    content_length = get_header(headers, "content-length")
    Logger.debug("Upstream headers: #{inspect(headers)}")
    Logger.debug("Upstream Content-Length: #{content_length}")
    Logger.debug("Initial data received with headers: #{byte_size(initial_data)} bytes, complete: #{body_complete?}")

    # Build the Phoenix response with proper headers
    conn =
      conn
      |> put_cors_headers()
      |> put_streaming_headers()
      |> copy_upstream_headers(headers)

    # Use non-chunked streaming when Content-Length is available (needed for AVPlayer)
    # Otherwise fall back to chunked encoding
    if content_length do
      # Send response with Content-Length using Cowboy/Bandit adapter directly
      # This allows streaming while preserving Content-Length header
      stream_with_content_length(conn, mint_conn, request_ref, normalize_status(status), content_length, initial_data, body_complete?)
    else
      # Fall back to chunked encoding when Content-Length is unknown
      conn = send_chunked(conn, normalize_status(status))
      # Send any initial data that came with headers
      conn = if byte_size(initial_data) > 0 do
        case chunk(conn, initial_data) do
          {:ok, conn} -> conn
          {:error, _} -> conn
        end
      else
        conn
      end
      # If body is already complete, don't try to read more
      if body_complete? do
        Mint.HTTP.close(mint_conn)
        conn
      else
        stream_body(conn, mint_conn, request_ref)
      end
    end
  end

  # For Range requests with known Content-Length under 50MB, buffer and send with send_resp
  # This avoids chunked encoding which corrupts byte offsets for video players
  @max_buffer_size 50 * 1024 * 1024

  defp stream_with_content_length(conn, mint_conn, request_ref, status, content_length, initial_data, body_complete?) do
    content_length_int = String.to_integer(content_length)

    if content_length_int <= @max_buffer_size do
      # Buffer small responses and send with send_resp (no chunked encoding)
      Logger.debug("Buffering response (#{content_length_int} bytes) for non-chunked delivery")
      buffer_and_send(conn, mint_conn, request_ref, status, content_length_int, initial_data, body_complete?)
    else
      # For large responses, use chunked encoding as fallback
      Logger.debug("Large response (#{content_length_int} bytes), using chunked encoding")
      conn = send_chunked(conn, status)
      # Send any initial data that came with headers
      conn = if byte_size(initial_data) > 0 do
        case chunk(conn, initial_data) do
          {:ok, conn} -> conn
          {:error, _} -> conn
        end
      else
        conn
      end
      # If body is already complete, don't try to read more
      if body_complete? do
        Mint.HTTP.close(mint_conn)
        conn
      else
        stream_body(conn, mint_conn, request_ref)
      end
    end
  end

  defp buffer_and_send(conn, mint_conn, _request_ref, status, _expected_size, initial_data, true = _body_complete?) do
    # Body is already complete - just send what we have
    Logger.debug("Body already complete, sending #{byte_size(initial_data)} bytes")
    Mint.HTTP.close(mint_conn)
    conn
    |> send_resp(status, initial_data)
  end

  defp buffer_and_send(conn, mint_conn, request_ref, status, expected_size, initial_data, false = _body_complete?) do
    # Use initial_data as starting accumulator - this data was already received with headers
    case collect_body(mint_conn, request_ref, initial_data, expected_size) do
      {:ok, body} ->
        Logger.debug("Buffered #{byte_size(body)} bytes, sending response")
        conn
        |> send_resp(status, body)

      {:error, reason} ->
        Logger.error("Failed to buffer response: #{inspect(reason)}")
        Mint.HTTP.close(mint_conn)

        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to read stream data"})
    end
  end

  defp collect_body(mint_conn, request_ref, acc, max_size) when byte_size(acc) > max_size do
    Mint.HTTP.close(mint_conn)
    {:error, :response_too_large}
  end

  defp collect_body(mint_conn, request_ref, acc, max_size) do
    receive do
      message ->
        case Mint.HTTP.stream(mint_conn, message) do
          :unknown ->
            collect_body(mint_conn, request_ref, acc, max_size)

          {:ok, mint_conn, responses} ->
            case process_collect_responses(responses, request_ref, acc) do
              {:continue, new_acc} ->
                collect_body(mint_conn, request_ref, new_acc, max_size)

              {:done, final_acc} ->
                Mint.HTTP.close(mint_conn)
                {:ok, final_acc}

              {:error, reason} ->
                Mint.HTTP.close(mint_conn)
                {:error, reason}
            end

          {:error, _mint_conn, reason, _responses} ->
            {:error, reason}
        end
    after
      @recv_timeout ->
        Mint.HTTP.close(mint_conn)
        {:error, :timeout}
    end
  end

  defp process_collect_responses([], _request_ref, acc) do
    {:continue, acc}
  end

  defp process_collect_responses([response | rest], request_ref, acc) do
    case response do
      {:data, ^request_ref, data} ->
        process_collect_responses(rest, request_ref, acc <> data)

      {:done, ^request_ref} ->
        {:done, acc}

      {:error, ^request_ref, reason} ->
        {:error, reason}

      _ ->
        process_collect_responses(rest, request_ref, acc)
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
        if status && length(headers) > 0 do
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

  defp stream_body(conn, mint_conn, request_ref) do
    receive do
      message ->
        case Mint.HTTP.stream(mint_conn, message) do
          :unknown ->
            stream_body(conn, mint_conn, request_ref)

          {:ok, mint_conn, responses} ->
            case process_body_responses(conn, responses, request_ref) do
              {:continue, conn} ->
                stream_body(conn, mint_conn, request_ref)

              {:done, conn} ->
                Mint.HTTP.close(mint_conn)
                conn

              {:error, conn} ->
                Mint.HTTP.close(mint_conn)
                conn
            end

          {:error, _mint_conn, reason, _responses} ->
            Logger.error("Stream body error: #{inspect(reason)}")
            conn
        end
    after
      @recv_timeout ->
        Logger.warning("Stream body timeout")
        Mint.HTTP.close(mint_conn)
        conn
    end
  end

  defp process_body_responses(conn, [], _request_ref) do
    {:continue, conn}
  end

  defp process_body_responses(conn, [response | rest], request_ref) do
    case response do
      {:data, ^request_ref, data} ->
        case chunk(conn, data) do
          {:ok, conn} ->
            process_body_responses(conn, rest, request_ref)

          {:error, _reason} ->
            {:error, conn}
        end

      {:done, ^request_ref} ->
        {:done, conn}

      {:error, ^request_ref, reason} ->
        Logger.error("Stream response error: #{inspect(reason)}")
        {:error, conn}

      _ ->
        process_body_responses(conn, rest, request_ref)
    end
  end

  defp normalize_status(206), do: 206
  defp normalize_status(_), do: 200

  defp copy_upstream_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, conn ->
      case String.downcase(key) do
        # Use put_resp_header directly to avoid Phoenix adding charset
        "content-type" -> put_resp_header(conn, "content-type", value)
        "content-length" -> put_resp_header(conn, "content-length", value)
        "content-range" -> put_resp_header(conn, "content-range", value)
        # Ignore upstream accept-ranges as some servers send malformed values
        # Always set it to "bytes" below
        "accept-ranges" -> conn
        _ -> conn
      end
    end)
    # Always set accept-ranges to "bytes" for video seeking support
    |> put_resp_header("accept-ranges", "bytes")
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

  defp put_streaming_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
    |> put_resp_header("x-accel-buffering", "no")
  end
end
