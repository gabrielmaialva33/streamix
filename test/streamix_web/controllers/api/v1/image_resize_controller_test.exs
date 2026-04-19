defmodule StreamixWeb.Api.V1.ImageResizeControllerTest do
  use StreamixWeb.ConnCase, async: false

  alias Plug.Conn
  alias StreamixWeb.Api.V1.ImageResizeController

  @api_key "test-resize-key"

  setup do
    cache_dir =
      Path.join(System.tmp_dir!(), "streamix_image_cache_#{System.unique_integer([:positive])}")

    File.mkdir_p!(cache_dir)

    original_cfg = Application.get_env(:streamix, ImageResizeController)
    Application.put_env(:streamix, ImageResizeController, cache_dir: cache_dir)

    original_keys = Application.get_env(:streamix, :api_keys)
    Application.put_env(:streamix, :api_keys, [@api_key])

    on_exit(fn ->
      File.rm_rf(cache_dir)

      if original_cfg,
        do: Application.put_env(:streamix, ImageResizeController, original_cfg),
        else: Application.delete_env(:streamix, ImageResizeController)

      if original_keys,
        do: Application.put_env(:streamix, :api_keys, original_keys),
        else: Application.delete_env(:streamix, :api_keys)
    end)

    {:ok, cache_dir: cache_dir}
  end

  defp authed_conn do
    build_conn()
    |> Conn.put_req_header("x-api-key", @api_key)
  end

  describe "GET /api/v1/catalog/images/resize" do
    test "returns 400 when the url param is missing" do
      conn = get(authed_conn(), "/api/v1/catalog/images/resize")
      assert response(conn, 400) =~ "missing url"
    end

    test "returns 400 when the url scheme is unsafe (SSRF guard)" do
      # UrlValidator rejects `file://` — catches an obvious local file
      # read attempt before we ever open a socket.
      conn = get(authed_conn(), "/api/v1/catalog/images/resize?url=file:///etc/passwd")
      assert response(conn, 400) =~ "invalid url"
    end

    test "returns 400 when the url points to a private IP literal" do
      conn = get(authed_conn(), "/api/v1/catalog/images/resize?url=http://127.0.0.1/x.jpg")
      assert response(conn, 400) =~ "invalid url"
    end

    # A note on the happy path: hitting real origins from the test
    # suite is flaky (network, TMDB rate limits, the CDN going down on
    # a Sunday). Instead we pre-seed the on-disk cache with a known
    # JPEG payload and assert that the controller serves it without
    # touching the network. That exercises the SSRF check, the cache
    # lookup, and the response headers — which is exactly the logic
    # that lives in this module.
    test "serves a cached response without hitting the network", %{cache_dir: cache_dir} do
      url = "https://tmdb.mahina.cloud/t/p/w780/example.jpg"
      width = 480
      quality = 80

      jpeg_bytes = minimal_jpeg()

      path = cache_path_for(cache_dir, url, width, nil, quality)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, jpeg_bytes)

      conn =
        get(authed_conn(), "/api/v1/catalog/images/resize", url: url, w: Integer.to_string(width))

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> List.first() =~ "image/jpeg"
      assert get_resp_header(conn, "x-image-source") == ["cache"]
      assert conn.resp_body == jpeg_bytes
    end

    test "falls back to the default width for out-of-ladder sizes", %{cache_dir: cache_dir} do
      # w=9999 isn't in the allowlist → the controller normalizes it to
      # the default (480). We verify by seeding the cache under 480 and
      # asking for 9999: if normalization works, we get the cached hit.
      url = "https://tmdb.mahina.cloud/t/p/w780/norm.jpg"
      jpeg_bytes = minimal_jpeg()
      path = cache_path_for(cache_dir, url, 480, nil, 80)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, jpeg_bytes)

      conn =
        get(authed_conn(), "/api/v1/catalog/images/resize", url: url, w: "9999")

      assert conn.status == 200
      assert get_resp_header(conn, "x-image-source") == ["cache"]
    end
  end

  # Same hashing the controller uses so the test can pre-seed the cache.
  defp cache_path_for(cache_dir, url, width, height, quality) do
    hash =
      :crypto.hash(:sha256, "#{url}|#{width}|#{height}|#{quality}")
      |> Base.encode16(case: :lower)

    <<a::binary-2, b::binary-2, _rest::binary>> = hash
    Path.join([cache_dir, a, b, hash <> ".jpg"])
  end

  # 1×1 valid JPEG. Kept as a binary literal so the test doesn't need
  # libvips at all — if the controller hands us the cached bytes
  # untouched we know the happy path works without having to regenerate
  # this fixture on every run.
  defp minimal_jpeg do
    <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF", 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01,
      0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43, 0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07,
      0x07, 0x07, 0x09, 0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
      0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20, 0x24, 0x2E, 0x27,
      0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29, 0x2C, 0x30, 0x31, 0x34, 0x34, 0x34,
      0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32, 0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B,
      0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00,
      0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0xFF, 0xC4, 0x00,
      0xB5, 0x10, 0x00, 0x02, 0x01, 0x03, 0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00,
      0x00, 0x01, 0x7D, 0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06,
      0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1,
      0xC1, 0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72, 0x82, 0xFF, 0xDA, 0x00, 0x08, 0x01,
      0x01, 0x00, 0x00, 0x3F, 0x00, 0xFB, 0xD0, 0xFF, 0xD9>>
  end
end
