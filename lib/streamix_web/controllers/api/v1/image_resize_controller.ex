defmodule StreamixWeb.Api.V1.ImageResizeController do
  @moduledoc """
  Image proxy + resize endpoint.

  Replaces the client-side dependency on `wsrv.nl` with an in-process
  pipeline:

      GET /api/v1/catalog/images/resize?url=<encoded>&w=480[&h=<n>][&q=<1-100>]

  Flow:
    1. Validate the `url` against `StreamixWeb.UrlValidator` — the same
       SSRF guard the stream proxy uses.
    2. Compute a deterministic cache key (`sha256(url|w|h|q)`) and check
       the on-disk cache. A hit is served directly as `image/jpeg` with a
       long `cache-control` header.
    3. On miss, fetch the origin via `Req`, resize with libvips
       (`Image.thumbnail!/2` — fit-inside semantics, keeps aspect ratio),
       encode to JPEG at the requested quality, persist, and serve.

  The cache directory is configurable via
  `config :streamix, #{inspect(__MODULE__)}, cache_dir: "/app/data/image_cache"`.
  A whitelist of widths prevents arbitrary-size amplification attacks.
  """

  use StreamixWeb, :controller

  alias StreamixWeb.Api.V1.Response
  alias StreamixWeb.UrlValidator

  require Logger

  # Discrete ladder of sizes we're willing to generate. Keeping this as
  # an explicit set stops a client from asking for `?w=17` on every
  # single request and filling the disk with near-duplicate files.
  @allowed_widths [120, 240, 360, 480, 640, 720, 960, 1080, 1280, 1920]
  @default_width 480
  @default_quality 80
  @max_upstream_bytes 10 * 1024 * 1024
  @max_redirects 3
  @upstream_timeout :timer.seconds(15)
  @default_cache_dir "/app/data/image_cache"
  @body_chunks_key :streamix_image_resize_chunks
  @body_size_key :streamix_image_resize_size
  @body_too_large_key :streamix_image_resize_too_large

  @spec resize(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def resize(conn, %{"url" => url} = params) when is_binary(url) and url != "" do
    width = parse_width(params["w"])
    height = parse_optional_width(params["h"])
    quality = parse_quality(params["q"])

    with :ok <- UrlValidator.validate_url(url),
         {:ok, bytes, source} <- fetch_or_cache(url, width, height, quality) do
      :telemetry.execute(
        [:streamix, :image_resize, :served],
        %{bytes: byte_size(bytes)},
        %{source: source, width: width}
      )

      conn
      |> put_resp_content_type("image/jpeg")
      |> put_resp_header("cache-control", "public, max-age=2592000, immutable")
      |> put_resp_header("x-image-source", Atom.to_string(source))
      |> send_resp(200, bytes)
    else
      {:error, :unsafe_url} ->
        Response.error(conn, :bad_request, "invalid_url", "invalid url")

      {:error, {:upstream_status, status}} ->
        Response.error(
          conn,
          :bad_gateway,
          "upstream_error",
          "upstream returned status #{status}"
        )

      {:error, :too_many_redirects} ->
        Response.error(
          conn,
          :bad_gateway,
          "too_many_redirects",
          "upstream redirected too many times"
        )

      {:error, :upstream_too_large} ->
        Response.error(conn, :bad_gateway, "upstream_too_large", "upstream too large")

      {:error, :upstream_unreachable} ->
        Response.error(conn, :bad_gateway, "upstream_unreachable", "upstream unreachable")

      {:error, :resize_failed} ->
        Response.error(conn, :internal_server_error, "resize_failed", "resize failed")
    end
  end

  def resize(conn, _params) do
    Response.error(conn, :bad_request, "missing_url", "missing url param")
  end

  # --- Private ---

  defp fetch_or_cache(url, width, height, quality) do
    path = cache_path(url, width, height, quality)

    case File.read(path) do
      {:ok, bytes} ->
        {:ok, bytes, :cache}

      {:error, _} ->
        with {:ok, origin_bytes} <- fetch_origin(url),
             {:ok, resized} <- resize_bytes(origin_bytes, width, height, quality),
             :ok <- write_cache(path, resized) do
          {:ok, resized, :origin}
        end
    end
  end

  defp fetch_origin(url), do: fetch_origin(url, 0)

  defp fetch_origin(url, redirect_count) do
    with :ok <- UrlValidator.validate_url(url),
         {:ok, response} <- Req.get(url, origin_request_options()) do
      handle_origin_response(response, url, redirect_count)
    else
      {:error, :unsafe_url} = error ->
        error

      {:error, reason} ->
        Logger.warning("[ImageResize] upstream fetch failed", reason_kind: reason_kind(reason))
        {:error, :upstream_unreachable}
    end
  end

  defp handle_origin_response(%Req.Response{status: 200} = response, _url, _redirect_count) do
    response_body(response)
  end

  defp handle_origin_response(%Req.Response{status: status} = response, url, redirect_count)
       when status in [301, 302, 303, 307, 308] do
    follow_redirect(response, url, redirect_count)
  end

  defp handle_origin_response(%Req.Response{status: status}, _url, _redirect_count) do
    {:error, {:upstream_status, status}}
  end

  defp follow_redirect(_response, _url, redirect_count) when redirect_count >= @max_redirects do
    {:error, :too_many_redirects}
  end

  defp follow_redirect(response, url, redirect_count) do
    with [location | _] <- Req.Response.get_header(response, "location"),
         {:ok, redirected_url} <- resolve_redirect_url(url, location),
         :ok <- UrlValidator.validate_url(redirected_url) do
      fetch_origin(redirected_url, redirect_count + 1)
    else
      {:error, :unsafe_url} = error -> error
      _ -> {:error, {:upstream_status, response.status}}
    end
  end

  defp resolve_redirect_url(current_url, location)
       when is_binary(location) and location != "" do
    {:ok, current_url |> URI.merge(location) |> URI.to_string()}
  rescue
    _error -> {:error, :invalid_redirect}
  end

  defp resolve_redirect_url(_current_url, _location), do: {:error, :invalid_redirect}

  defp origin_request_options do
    configured =
      Application.get_env(:streamix, __MODULE__, [])
      |> Keyword.get(:request_options, [])

    secured = [
      receive_timeout: @upstream_timeout,
      redirect: false,
      retry: false,
      decode_body: false,
      into: &collect_bounded_body/2,
      finch: [name: Streamix.Finch]
    ]

    Keyword.merge(configured, secured)
  end

  defp collect_bounded_body({:data, data}, {request, %Req.Response{status: 200} = response}) do
    current_size = Req.Response.get_private(response, @body_size_key, 0)
    next_size = current_size + byte_size(data)

    if next_size > @max_upstream_bytes or oversized_content_length?(response) do
      response = Req.Response.put_private(response, @body_too_large_key, true)
      {:halt, {request, response}}
    else
      chunks = Req.Response.get_private(response, @body_chunks_key, [])

      response =
        response
        |> Req.Response.put_private(@body_size_key, next_size)
        |> Req.Response.put_private(@body_chunks_key, [data | chunks])

      {:cont, {request, response}}
    end
  end

  defp collect_bounded_body({:data, _data}, state), do: {:cont, state}

  defp response_body(response) do
    cond do
      Req.Response.get_private(response, @body_too_large_key, false) ->
        {:error, :upstream_too_large}

      oversized_content_length?(response) ->
        {:error, :upstream_too_large}

      true ->
        body = collected_body(response)

        if byte_size(body) <= @max_upstream_bytes,
          do: {:ok, body},
          else: {:error, :upstream_too_large}
    end
  end

  defp collected_body(response) do
    case Req.Response.get_private(response, @body_chunks_key) do
      chunks when is_list(chunks) -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
      nil when is_binary(response.body) -> response.body
      nil -> ""
    end
  end

  defp oversized_content_length?(response) do
    Enum.any?(Req.Response.get_header(response, "content-length"), fn value ->
      case Integer.parse(value) do
        {length, ""} -> length > @max_upstream_bytes
        _ -> false
      end
    end)
  end

  defp reason_kind(%module{}), do: module

  defp resize_bytes(bytes, width, height, quality) do
    with {:ok, image} <- Image.from_binary(bytes),
         {:ok, resized} <- thumbnail(image, width, height),
         {:ok, encoded} <- Image.write(resized, :memory, suffix: ".jpg", quality: quality) do
      {:ok, encoded}
    else
      error ->
        Logger.warning("[ImageResize] resize failed: #{inspect(error)}")
        {:error, :resize_failed}
    end
  end

  # When the caller only specifies `w`, `Image.thumbnail!/2` treats it as
  # "fit inside a width × width box with aspect-ratio preserved" — the
  # actual pixel count on the long edge never exceeds `width`, which is
  # what we want for poster thumbnails that arrive in different ratios.
  defp thumbnail(image, width, nil), do: Image.thumbnail(image, width)

  defp thumbnail(image, width, height),
    do: Image.thumbnail(image, "#{width}x#{height}")

  # `path` is always cache_path/4 output: a configured root plus a SHA-256
  # digest. No request path or filename is ever joined into it.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_cache(path, bytes) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, bytes) do
      :ok
    else
      {:error, reason} ->
        # Disk cache is best-effort: an ENOSPC or permission issue shouldn't
        # block the response, we just log and serve the freshly-resized
        # bytes anyway.
        Logger.warning("[ImageResize] cache write failed at #{path}: #{inspect(reason)}")
        :ok
    end
  end

  defp cache_path(url, width, height, quality) do
    hash =
      :crypto.hash(:sha256, "#{url}|#{width}|#{height}|#{quality}") |> Base.encode16(case: :lower)

    # Fan out into two-character prefix folders so the directory listing
    # stays manageable once the cache grows past a few thousand files.
    <<a::binary-2, b::binary-2, _rest::binary>> = hash
    Path.join([cache_dir(), a, b, hash <> ".jpg"])
  end

  defp cache_dir do
    Application.get_env(:streamix, __MODULE__, [])
    |> Keyword.get(:cache_dir, @default_cache_dir)
  end

  defp parse_width(nil), do: @default_width
  defp parse_width(""), do: @default_width

  defp parse_width(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n in @allowed_widths -> n
      _ -> @default_width
    end
  end

  defp parse_width(n) when is_integer(n) and n in @allowed_widths, do: n
  defp parse_width(_), do: @default_width

  # Height is optional. When present it must also be one of the allowed
  # widths — we reuse the ladder to cap both dimensions with the same
  # guarantee.
  defp parse_optional_width(nil), do: nil
  defp parse_optional_width(""), do: nil

  defp parse_optional_width(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n in @allowed_widths -> n
      _ -> nil
    end
  end

  defp parse_optional_width(_), do: nil

  defp parse_quality(nil), do: @default_quality
  defp parse_quality(""), do: @default_quality

  defp parse_quality(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n in 1..100 -> n
      _ -> @default_quality
    end
  end

  defp parse_quality(n) when is_integer(n) and n in 1..100, do: n
  defp parse_quality(_), do: @default_quality
end
