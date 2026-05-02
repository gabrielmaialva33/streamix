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

  alias Streamix.Iptv.Channels
  alias StreamixWeb.Plugs.ApiKeyAuth
  alias StreamixWeb.StreamErrors
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
    # A valid X-API-Key acts as integration-level authorization: the caller
    # (TV / mobile app) is trusted to have already authenticated its end
    # user out-of-band, so we skip the subscription / premium check. This
    # is how the MVP TV app — which has no login yet — streams global
    # catalog content.
    opts = [bypass_subscription: ApiKeyAuth.valid_api_key?(conn)]

    case StreamToken.verify_and_get_url(token, opts) do
      {:ok, url, content_type, meta} ->
        Logger.debug("Stream proxy: #{content_type} url=#{sanitize_url(url)}")
        stream_by_type(conn, url, content_type, meta)

      {:error, reason} ->
        token_error(conn, reason)
    end
  end

  def proxy(conn, _params), do: StreamErrors.halt(conn, :missing_token)

  # Live channels: stream directly to avoid cross-origin redirect CORS failures.
  # VOD: redirect to nginx proxy for Range header support.
  defp stream_by_type(conn, url, "channel", meta),
    do: stream_live_channel(conn, url, meta.content_id)

  defp stream_by_type(conn, url, _type, _meta),
    do: resolve_and_redirect_to_proxy(conn, url)

  # Map StreamToken's raw reasons onto the canonical StreamErrors codes
  # so controllers and TV clients speak the same vocabulary.
  @token_errors %{
    token_expired: :token_expired,
    invalid_token: :invalid_token,
    subscription_required: :subscription_required,
    not_found: :content_not_found,
    unauthorized: :token_unauthorized,
    unsafe_url: :unsafe_url
  }

  defp token_error(conn, reason) do
    code = Map.get(@token_errors, reason, :unknown)
    StreamErrors.halt(conn, code)
  end

  # --- Live channels: stream directly through Elixir (no redirect) ---

  defp stream_live_channel(conn, url, channel_id) do
    case resolve_final_url(url, 0) do
      {:ok, final_url} ->
        # Resolved cleanly — clear any stale dead flag from prior failures.
        if channel_id, do: Channels.mark_alive(channel_id)
        do_stream_live(conn, final_url)

      {:error, {:unexpected_status, 404}} = error ->
        # Upstream explicitly said the channel is gone. Hide it from listings
        # for the recheck window so users don't keep hitting dead entries.
        if channel_id do
          Logger.warning("Stream proxy: marking channel #{channel_id} dead (upstream 404)")
          Channels.mark_dead(channel_id)
        end

        live_resolve_failed(conn, error)

      {:error, reason} ->
        live_resolve_failed(conn, {:error, reason})
    end
  end

  defp live_resolve_failed(conn, {:error, reason}) do
    Logger.error("Stream proxy: live resolve failed: #{inspect(reason)}")
    StreamErrors.halt(conn, StreamErrors.code_from_reason(reason))
  end

  defp do_stream_live(conn, final_url) do
    Logger.debug("Stream proxy: live streaming → #{sanitize_url(final_url)}")

    conn =
      conn
      |> put_resp_content_type("video/mp2t")
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("access-control-expose-headers", "Content-Type")
      |> put_resp_header("cache-control", "no-cache, no-store")
      |> send_chunked(200)

    result =
      Req.get(
        final_url,
        req_options(
          receive_timeout: :infinity,
          compressed: false,
          into: fn {:data, data}, {req, resp} ->
            case Plug.Conn.chunk(conn, data) do
              {:ok, _conn} -> {:cont, {req, resp}}
              {:error, :closed} -> {:halt, {req, resp}}
            end
          end
        )
      )

    case result do
      {:ok, _} ->
        conn

      {:error, reason} ->
        Logger.debug("Stream proxy: live stream ended: #{inspect(reason)}")
        conn
    end
  end

  # --- VOD: resolve redirects and send to nginx proxy for Range support ---

  defp resolve_and_redirect_to_proxy(conn, url) do
    # O nginx em source.mahina.cloud já segue cadeia de redirects via Lua,
    # com cache + UA stealth. Quando a URL inicial vem com creds IPTV
    # (/movie/USER/PASS/...) só andamos a chain o suficiente pra trocar
    # essas creds por um token de curta duração — o resto dos hops lentos
    # (vauth → vauth → vauth) roda no nginx, sem segurar BEAM. Se a URL
    # já vem limpa, mantém o chase deep antigo (sem regressão).
    stop_fn =
      if credentials_in_url?(url) do
        fn next_url -> not credentials_in_url?(next_url) end
      else
        fn _ -> false end
      end

    case resolve_final_url(url, 0, stop_fn) do
      {:ok, final_url} ->
        proxy_base =
          Application.get_env(:streamix, :stream_proxy_url, "https://source.mahina.cloud")

        with {:ok, final_proxy} <- build_proxy_redirect_url(proxy_base, final_url),
             :ok <- ensure_final_url_stays_server_side(final_url, proxy_base) do
          Logger.debug("Stream proxy: VOD resolved → #{sanitize_url(final_url)}")

          conn
          |> put_resp_header("cache-control", "no-cache, no-store")
          |> redirect(external: final_proxy)
        else
          {:error, :unsafe_proxy_base} ->
            Logger.error(
              "Stream proxy: BLOCKED — invalid stream proxy base #{inspect(proxy_base)}"
            )

            StreamErrors.halt(conn, :stream_resolution_failed)

          {:error, :credentials_would_escape} ->
            Logger.error("Stream proxy: BLOCKED — final URL still contains credentials")
            StreamErrors.halt(conn, :stream_resolution_failed)
        end

      {:error, reason} ->
        Logger.error("Stream proxy: VOD resolve failed: #{inspect(reason)}")
        StreamErrors.halt(conn, StreamErrors.code_from_reason(reason))
    end
  end

  # Resolve all redirects using GET with immediate halt.
  # HEAD is unreliable (many IPTV providers return 200 for HEAD on all URLs).
  # GET with halt_after_first_chunk follows the real redirect chain without
  # downloading the full response body.
  defp resolve_final_url(url, count, stop_fn \\ fn _ -> false end)

  defp resolve_final_url(_url, count, _stop_fn) when count > @max_redirects do
    {:error, :too_many_redirects}
  end

  defp resolve_final_url(url, count, stop_fn) do
    case Req.get(url, req_options(into: &halt_after_first_chunk/2)) do
      {:ok, %{status: status, headers: headers}} when status in [301, 302, 303, 307, 308] ->
        follow_resolved_redirect(url, headers, count, stop_fn)

      {:ok, %{status: status}} when status in 200..299 ->
        {:ok, url}

      {:ok, %{status: status}} ->
        Logger.error(
          "Stream proxy: GET resolve got unexpected status #{status} for #{sanitize_url(url)}"
        )

        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp req_options(extra) do
    # Probing chokitecnologia from the VPS revealed the actual cost:
    # `cb` returns a 302 in ~1.5s but the next `vauth` server in the
    # chain takes another 7-8s per hop and still hands back another
    # 302. Two hops alone sit at 9-10s, three at ~17s. Worse, Req's
    # default retry policy (3 attempts with 1s/2s/4s backoff) was
    # multiplying that on top of every timeout, producing the 27s+
    # 504s the user was seeing.
    #
    # Solution: disable Req's retry layer (one shot is enough — if
    # the chain is genuinely slow, retrying just adds 7s per attempt
    # and ends in the same place) and lift the receive_timeout to 30s
    # so a 3-hop chain has room. Connect timeout stays modest (12s) —
    # if the SYN doesn't land in 12s the host is filtered, no retry
    # will save it.
    [
      redirect: false,
      retry: false,
      headers: [{"user-agent", "VLC/3.0.20 LibVLC/3.0.20"}],
      decode_body: false,
      receive_timeout: 30_000,
      connect_options: [timeout: 12_000]
    ]
    |> Keyword.merge(Application.get_env(:streamix, :stream_proxy_req_options, []))
    |> Keyword.merge(extra)
  end

  defp halt_after_first_chunk({:data, _chunk}, {request, response}) do
    {:halt, {request, response}}
  end

  defp follow_resolved_redirect(url, headers, count, stop_fn) do
    case List.first(Map.get(headers, "location", [])) do
      nil ->
        {:error, :missing_location}

      location ->
        next_url = resolve_redirect_location(url, location)
        Logger.debug("Stream proxy: resolve redirect #{count + 1} → #{sanitize_url(next_url)}")

        if stop_fn.(next_url) do
          # Caller pediu pra parar quando ficar seguro (ex.: credenciais já
          # foram trocadas por token). O resto da cadeia — normalmente a
          # parte lenta — será percorrida pelo nginx upstream.
          {:ok, next_url}
        else
          resolve_final_url(next_url, count + 1, stop_fn)
        end
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

  defp ensure_final_url_stays_server_side(final_url, proxy_base) do
    if credentials_in_url?(final_url) and not trusted_proxy_base?(proxy_base) do
      {:error, :credentials_would_escape}
    else
      :ok
    end
  end

  defp build_proxy_redirect_url(proxy_base, final_url) do
    if trusted_proxy_base?(proxy_base) do
      normalized_base = String.trim_trailing(proxy_base, "/")
      {:ok, "#{normalized_base}/proxy?url=#{URI.encode_www_form(final_url)}"}
    else
      {:error, :unsafe_proxy_base}
    end
  end

  defp trusted_proxy_base?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp trusted_proxy_base?(_), do: false

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
