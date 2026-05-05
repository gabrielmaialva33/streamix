defmodule StreamixWeb.StreamController do
  @moduledoc """
  Controller for proxying IPTV streams.

  Default backend is `Streamix.Iptv.Streaming.VodProxy` which pumps
  upstream bytes through the BEAM via `Finch.stream/5` +
  `Plug.Conn.chunk/2`. Set `STREAM_PROXY_BACKEND=redirect` to fall
  back to the 302-to-source-proxy flow handled by
  `resolve_and_redirect_to_proxy/2` below.
  """
  use StreamixWeb, :controller

  require Logger

  alias Streamix.Iptv.Streaming.{RedirectResolver, VodProxy}
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

  defp stream_by_type(conn, url, _type, _meta) do
    case Application.get_env(:streamix, :stream_proxy_backend, :beam) do
      :redirect -> resolve_and_redirect_to_proxy(conn, url)
      _ -> VodProxy.pipe(conn, url)
    end
  end

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

  # --- All streaming types: resolve redirects and send to source proxy ---

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

    case RedirectResolver.resolve(url, stop_fn: stop_fn) do
      {:ok, final_url} ->
        # Pick a source proxy from the configured pool. Each request
        # gets a different source (round-robin across the user's session
        # via the request_id, falling back to deterministic-by-URL
        # when no request_id is set). This matters because each source
        # sits behind a different ASN, and the IPTV provider's WAF
        # bans different vauth IPs depending on the source ASN — using
        # 2 sources roughly doubles the cluster surface available to us.
        proxy_base = pick_source_proxy(conn, final_url)

        with {:ok, final_proxy} <- build_proxy_redirect_url(proxy_base, final_url),
             :ok <- ensure_final_url_stays_server_side(final_url, proxy_base) do
          Logger.debug(
            "Stream proxy: VOD resolved → #{sanitize_url(final_url)} via #{proxy_base}"
          )

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

        if transient_error?(reason) do
          retry_later(conn)
        else
          StreamErrors.halt(conn, StreamErrors.code_from_reason(reason))
        end
    end
  end

  # Network/timeout style errors get a 503 + Retry-After:1 instead of the
  # default 504. The hls.js / mpegts loaders treat 503 + Retry-After as a
  # transparent retry signal, so the user does not see a fatal "manifest
  # load error" toast on the first cold-cache hit.
  defp retry_later(conn) do
    conn
    |> put_resp_header("retry-after", "1")
    |> put_resp_header("access-control-allow-origin", "*")
    |> send_resp(503, "")
    |> halt()
  end

  # Picks a source proxy URL from the configured pool. Configurable
  # via `:streamix, :stream_proxy_urls` (list) — falls back to the
  # legacy `:stream_proxy_url` (single) for backwards compatibility,
  # and ultimately to source.mahina.cloud.
  #
  # The choice is randomized per-request (not deterministic per URL)
  # because cb.chokitecnologia returns a different vauth IP based on
  # the source ASN — alternating sources roughly doubles the surface
  # of healthy IPs available to us. Stickiness is not required: the
  # nginx-side rewrite chain only sees one source per browser hop.
  defp pick_source_proxy(_conn, _final_url) do
    case Application.get_env(:streamix, :stream_proxy_urls) do
      [_ | _] = list ->
        Enum.random(list)

      _ ->
        Application.get_env(:streamix, :stream_proxy_url, "https://source.mahina.cloud")
    end
  end

  defp transient_error?({:resolver_crashed, _, _}), do: true
  defp transient_error?(:too_many_redirects), do: false
  defp transient_error?(:missing_location), do: false
  # Resolver gave up after retrying through dead cluster IPs. Tell the
  # player to retry — the provider's round-robin will eventually land
  # on a healthy node.
  defp transient_error?(:provider_unreachable), do: true

  defp transient_error?(%Req.TransportError{reason: reason}),
    do: reason in [:timeout, :closed, :econnrefused, :nxdomain, :ehostunreach]

  defp transient_error?(:timeout), do: true
  defp transient_error?({:unexpected_status, status}) when status in [502, 503, 504], do: true
  defp transient_error?(_), do: false

  # Redirect-chain resolution lives in `Streamix.Iptv.Streaming.RedirectResolver`.
  # The controller calls `RedirectResolver.resolve/2`; the same module is
  # also used by `PlayerLive.mount/3` to prewarm the cache.

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
