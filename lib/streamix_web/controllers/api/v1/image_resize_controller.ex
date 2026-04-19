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

  alias StreamixWeb.UrlValidator

  require Logger

  # Discrete ladder of sizes we're willing to generate. Keeping this as
  # an explicit set stops a client from asking for `?w=17` on every
  # single request and filling the disk with near-duplicate files.
  @allowed_widths [120, 240, 360, 480, 640, 720, 960, 1080, 1280, 1920]
  @default_width 480
  @default_quality 80
  @max_upstream_bytes 10 * 1024 * 1024
  @upstream_timeout :timer.seconds(15)
  @default_cache_dir "/app/data/image_cache"

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
        send_resp(conn, 400, "invalid url")

      {:error, {:upstream_status, status}} ->
        send_resp(conn, 502, "upstream #{status}")

      {:error, :upstream_too_large} ->
        send_resp(conn, 502, "upstream too large")

      {:error, :upstream_unreachable} ->
        send_resp(conn, 502, "upstream unreachable")

      {:error, :resize_failed} ->
        send_resp(conn, 500, "resize failed")
    end
  end

  def resize(conn, _params) do
    send_resp(conn, 400, "missing url param")
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

  defp fetch_origin(url) do
    case Req.get(url,
           receive_timeout: @upstream_timeout,
           max_redirects: 3,
           decode_body: false,
           finch: Streamix.Finch
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        if byte_size(body) > @max_upstream_bytes do
          {:error, :upstream_too_large}
        else
          {:ok, body}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:upstream_status, status}}

      {:error, reason} ->
        Logger.warning("[ImageResize] upstream fetch failed: #{inspect(reason)}")
        {:error, :upstream_unreachable}
    end
  end

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
      {n, _} when n in @allowed_widths -> n
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
      {n, _} when n in @allowed_widths -> n
      _ -> nil
    end
  end

  defp parse_optional_width(_), do: nil

  defp parse_quality(nil), do: @default_quality
  defp parse_quality(""), do: @default_quality

  defp parse_quality(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, _} when n in 1..100 -> n
      _ -> @default_quality
    end
  end

  defp parse_quality(n) when is_integer(n) and n in 1..100, do: n
  defp parse_quality(_), do: @default_quality
end
