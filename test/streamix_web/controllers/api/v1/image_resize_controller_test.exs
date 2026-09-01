defmodule StreamixWeb.Api.V1.ImageResizeControllerTest do
  use StreamixWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Plug.Conn
  alias StreamixWeb.Api.V1.ImageResizeController

  @api_key "test-resize-key"

  setup {Req.Test, :verify_on_exit!}

  setup do
    cache_dir =
      Path.join(System.tmp_dir!(), "streamix_image_cache_#{System.unique_integer([:positive])}")

    File.mkdir_p!(cache_dir)

    original_cfg = Application.get_env(:streamix, ImageResizeController)

    Application.put_env(:streamix, ImageResizeController,
      cache_dir: cache_dir,
      request_options: [plug: {Req.Test, __MODULE__}]
    )

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
      capture_log(fn ->
        conn = get(authed_conn(), "/api/v1/catalog/images/resize?url=file:///etc/passwd")
        assert response(conn, 400) =~ "invalid url"
      end)
    end

    test "returns 400 when the url points to a private IP literal" do
      capture_log(fn ->
        conn = get(authed_conn(), "/api/v1/catalog/images/resize?url=http://127.0.0.1/x.jpg")
        assert response(conn, 400) =~ "invalid url"
      end)
    end

    test "blocks a public origin redirecting to a private address" do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Conn.put_resp_header("location", "http://127.0.0.1/internal.jpg")
        |> Conn.send_resp(302, "")
      end)

      capture_log(fn ->
        response =
          authed_conn()
          |> get("/api/v1/catalog/images/resize", url: "https://example.com/redirect.jpg")
          |> json_response(400)

        assert response["error"]["code"] == "invalid_url"
      end)
    end

    test "follows a validated relative redirect and streams a bounded image body" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/redirect.jpg"

        conn
        |> Conn.put_resp_header("location", "/final.jpg")
        |> Conn.send_resp(302, "")
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/final.jpg"
        Conn.send_resp(conn, 200, minimal_jpeg())
      end)

      conn =
        get(authed_conn(), "/api/v1/catalog/images/resize",
          url: "https://example.com/redirect.jpg"
        )

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> List.first() =~ "image/jpeg"
      assert get_resp_header(conn, "x-image-source") == ["origin"]
      assert byte_size(conn.resp_body) > 0
    end

    test "rejects an oversized response from content-length before resizing" do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Conn.put_resp_header("content-length", Integer.to_string(10 * 1024 * 1024 + 1))
        |> Conn.send_resp(200, "")
      end)

      response =
        authed_conn()
        |> get("/api/v1/catalog/images/resize", url: "https://example.com/large.jpg")
        |> json_response(502)

      assert response["error"]["code"] == "upstream_too_large"
    end

    # A note on the happy path: hitting real origins from the test
    # suite is flaky (network, TMDB rate limits, the CDN going down on
    # a Sunday). Instead we pre-seed the on-disk cache with a known
    # JPEG payload and assert that the controller serves it without
    # touching the network. That exercises the SSRF check, the cache
    # lookup, and the response headers — which is exactly the logic
    # that lives in this module.
    test "serves a cached response without hitting the network", %{cache_dir: cache_dir} do
      url = "https://tmdb.mahina.fun/t/p/w780/example.jpg"
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
      url = "https://tmdb.mahina.fun/t/p/w780/norm.jpg"
      jpeg_bytes = minimal_jpeg()
      path = cache_path_for(cache_dir, url, 480, nil, 80)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, jpeg_bytes)

      conn =
        get(authed_conn(), "/api/v1/catalog/images/resize", url: url, w: "9999")

      assert conn.status == 200
      assert get_resp_header(conn, "x-image-source") == ["cache"]
    end

    test "does not accept valid numeric prefixes in resize params", %{cache_dir: cache_dir} do
      url = "https://tmdb.mahina.fun/t/p/w780/strict.jpg"
      jpeg_bytes = minimal_jpeg()
      path = cache_path_for(cache_dir, url, 480, nil, 80)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, jpeg_bytes)

      conn =
        get(authed_conn(), "/api/v1/catalog/images/resize",
          url: url,
          w: "720pixels",
          h: "360pixels",
          q: "50percent"
        )

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

  defp minimal_jpeg do
    2
    |> Image.new!(2, color: :white)
    |> Image.write!(:memory, suffix: ".jpg")
  end
end
