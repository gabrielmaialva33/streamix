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

  @doc """
  Proxies a stream URL with chunked transfer.
  Supports HTTP Range requests for seeking.
  """
  def proxy(conn, %{"url" => encoded_url}) do
    case Base.url_decode64(encoded_url, padding: false) do
      {:ok, url} ->
        stream_url(conn, url, 0)

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid URL encoding"})
    end
  end

  def proxy(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing url parameter"})
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
      [range] -> [{"range", range} | headers]
      _ -> headers
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
      {:ok, mint_conn, status, headers} ->
        cond do
          # Handle redirects (301, 302, 303, 307, 308)
          status in [301, 302, 303, 307, 308] ->
            Mint.HTTP.close(mint_conn)
            handle_redirect(conn, headers, original_url, redirect_count)

          # Normal response - stream it
          true ->
            stream_response(conn, mint_conn, request_ref, status, headers)
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

  defp stream_response(conn, mint_conn, request_ref, status, headers) do
    # Build the Phoenix response with proper headers
    conn =
      conn
      |> put_cors_headers()
      |> put_streaming_headers()
      |> copy_upstream_headers(headers)
      |> send_chunked(normalize_status(status))

    # Stream the body
    stream_body(conn, mint_conn, request_ref)
  end

  defp receive_headers(mint_conn, request_ref) do
    receive_headers_loop(mint_conn, request_ref, nil, [])
  end

  defp receive_headers_loop(mint_conn, request_ref, status, headers) do
    receive do
      message ->
        case Mint.HTTP.stream(mint_conn, message) do
          :unknown ->
            receive_headers_loop(mint_conn, request_ref, status, headers)

          {:ok, mint_conn, responses} ->
            case process_header_responses(responses, request_ref, status, headers) do
              {:continue, new_status, new_headers} ->
                receive_headers_loop(mint_conn, request_ref, new_status, new_headers)

              {:done, final_status, final_headers} ->
                {:ok, mint_conn, final_status, final_headers}

              {:data, final_status, final_headers} ->
                # We got data before finishing headers, return what we have
                {:ok, mint_conn, final_status, final_headers}

              {:error, reason} ->
                {:error, mint_conn, reason}
            end

          {:error, mint_conn, reason, _responses} ->
            {:error, mint_conn, reason}
        end
    after
      @recv_timeout ->
        {:error, mint_conn, :timeout}
    end
  end

  defp process_header_responses([], _request_ref, status, headers) do
    {:continue, status, headers}
  end

  defp process_header_responses([response | rest], request_ref, status, headers) do
    case response do
      {:status, ^request_ref, new_status} ->
        process_header_responses(rest, request_ref, new_status, headers)

      {:headers, ^request_ref, new_headers} ->
        all_headers = headers ++ new_headers
        process_header_responses(rest, request_ref, status, all_headers)

      {:data, ^request_ref, _data} ->
        # Got data, headers are complete
        {:data, status, headers}

      {:done, ^request_ref} ->
        {:done, status, headers}

      {:error, ^request_ref, reason} ->
        {:error, reason}

      _ ->
        process_header_responses(rest, request_ref, status, headers)
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
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, HEAD, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "Range, Accept-Encoding")
    |> put_resp_header(
      "access-control-expose-headers",
      "Content-Length, Content-Range, Accept-Ranges"
    )
  end

  defp put_streaming_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
    |> put_resp_header("x-accel-buffering", "no")
  end
end
