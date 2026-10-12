defmodule StreamixWeb.EmbedplayStreamControllerTest do
  use StreamixWeb.ConnCase, async: false

  alias Streamix.{Catalog, Embedplay, Providers}
  alias StreamixWeb.Catalog.StreamUrls
  alias StreamixWeb.Endpoint
  alias StreamixWeb.PlayerComponents.Metadata
  alias StreamixWeb.PlayerHelpers
  alias StreamixWeb.StreamToken

  # A stand-in progressive file: bytes 4..8 are the `ftyp` box type.
  @movie_bytes <<0, 0, 0, 24>> <> "ftypisom" <> String.duplicate("m", 52)

  setup do
    original = Application.get_env(:streamix, :embedplay, [])

    Application.put_env(:streamix, :embedplay,
      enabled: true,
      resolver_url: "http://127.0.0.1:9999",
      resolver_token: "test-only",
      http_options: [plug: {Req.Test, __MODULE__}]
    )

    Req.Test.set_req_test_to_shared()
    {:ok, id} = Embedplay.import_movie(System.unique_integer([:positive]))
    movie = Catalog.get_public_movie(id)
    token = StreamToken.sign_movie(id, nil, bypass_subscription: true)
    on_exit(fn -> Application.put_env(:streamix, :embedplay, original) end)
    %{movie: movie, token: token, master: "/api/stream/embedplay/master.m3u8?token=#{token}"}
  end

  test "HEAD authorizes and advertises HLS without launching a resolver", %{
    conn: conn,
    master: master
  } do
    response = head(conn, master)
    assert response.status == 200

    assert get_resp_header(response, "content-type") == [
             "application/vnd.apple.mpegurl; charset=utf-8"
           ]

    assert response.resp_body == ""
  end

  test "master, media, key, init and ranged segment remain behind opaque authorized routes",
       context do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(
        owner,
        {:upstream, conn.request_path, conn.query_string, get_req_header(conn, "range")}
      )

      fixture_response(conn)
    end)

    master = get(context.conn, context.master)
    assert master.status == 200
    refute master.resp_body =~ "93.184.216.34"
    assert_receive {:upstream, "/resolve", "", []}
    assert_receive {:upstream, "/root/master.m3u8", "signed=a%2Fb", []}

    media_path =
      master.resp_body |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "/api/"))

    media = get(recycle(master), media_path)
    assert media.status == 200
    assert_receive {:upstream, "/root/video.m3u8", "signature=x%2By", []}
    refute media.resp_body =~ "93.184.216.34"

    [key_path, init_path] =
      Regex.scan(~r/URI="([^"]+)"/, media.resp_body) |> Enum.map(&List.last/1)

    assert get(build_conn(), key_path).resp_body == "0123456789abcdef"
    assert get(build_conn(), init_path).resp_body == "init"
    assert_receive {:upstream, "/key", "key=one", []}
    assert_receive {:upstream, "/root/init.mp4", "", []}

    segment_path =
      media.resp_body |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "/api/"))

    segment = build_conn() |> put_req_header("range", "bytes=2-4") |> get(segment_path)
    assert segment.status == 206
    assert segment.resp_body == "234"
    assert get_resp_header(segment, "content-range") == ["bytes 2-4/10"]
    assert get_resp_header(segment, "access-control-allow-origin") == ["*"]
    assert_receive {:upstream, "/root/segment.ts", "piece=1%2F2", ["bytes=2-4"]}

    bad_token_path = String.replace(segment_path, context.token, "invalid")
    assert get(build_conn(), bad_token_path).status == 401
    unknown = String.replace(segment_path, ~r{/[^/]+\.bin\?}, "/unknown.bin?")
    assert get(build_conn(), unknown).status == 404
  end

  test "invalid, expired, non-entitled and inactive content tokens are rejected", context do
    assert get(build_conn(), "/api/stream/embedplay/master.m3u8?token=bad").status == 401
    token = StreamToken.sign_movie(context.movie.id, nil)
    assert head(build_conn(), "/api/stream/embedplay/master.m3u8?token=#{token}").status == 403

    expired =
      Phoenix.Token.sign(
        Endpoint,
        "stream",
        %{type: "movie", id: context.movie.id, user_id: nil, bypass: true},
        signed_at: System.system_time(:second) - 7300
      )

    response = head(build_conn(), "/api/stream/embedplay/master.m3u8?token=#{expired}")
    assert response.status == 401

    Providers.update_provider(context.movie.provider, %{is_active: false})
    assert head(build_conn(), context.master).status == 401
  end

  test "a degraded provider refuses playback at once, without reaching the resolver", context do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:upstream, conn.request_path})
      fixture_response(conn)
    end)

    {:ok, _provider} = Providers.mark_embedplay_degraded(:resolver_outdated)

    response = get(context.conn, context.master)

    assert response.status == 503
    assert %{"error" => %{"code" => "provider_degraded"}} = json_response(response, 503)
    assert get_resp_header(response, "access-control-allow-origin") == ["*"]
    refute_received {:upstream, _path}
  end

  test "disabling the provider rejects playback and CORS preflight remains available", context do
    Application.put_env(:streamix, :embedplay, enabled: false)
    assert get(build_conn(), context.master).status == 503
    response = options(build_conn(), "/api/stream/embedplay/master.m3u8")
    assert response.status == 204
    assert get_resp_header(response, "access-control-allow-methods") == ["GET, HEAD, OPTIONS"]
  end

  test "concurrent first opens coalesce; unknown resources and expired sessions do not renew segments",
       context do
    Req.Test.expect(__MODULE__, fn conn -> fixture_response(conn) end)
    tasks = for _ <- 1..8, do: Task.async(fn -> Embedplay.open_movie(context.movie) end)

    sessions =
      Enum.map(tasks, fn task ->
        assert {:ok, session} = Task.await(task)
        session
      end)

    assert length(Enum.uniq(sessions)) == 1
    [session | _] = sessions

    assert {:error, :resource_not_found} =
             Embedplay.fetch_resource(
               session.session_id,
               session.resource_id,
               context.movie.id + 1
             )

    Embedplay.invalidate_session(session.session_id)

    assert {:error, :resource_not_found} =
             Embedplay.fetch_resource(session.session_id, session.resource_id, context.movie.id)
  end

  test "upstream auth expiry invalidates the resource graph and next open resolves again",
       context do
    Req.Test.stub(__MODULE__, fn conn -> fixture_response(conn) end)
    assert {:ok, first} = Embedplay.open_movie(context.movie)
    Req.Test.stub(__MODULE__, fn conn -> send_resp(conn, 403, "expired upstream credential") end)

    assert {:error, :playback_restart_required} =
             Embedplay.fetch_resource(first.session_id, first.resource_id, context.movie.id)

    Req.Test.stub(__MODULE__, fn conn -> fixture_response(conn) end)
    assert {:ok, second} = Embedplay.open_movie(context.movie)
    refute first.session_id == second.session_id
  end

  test "resolution cache expiry preserves active playback; idle cleanup releases its graph",
       context do
    alias Streamix.Embedplay.Sessions

    Req.Test.stub(__MODULE__, &fixture_response/1)
    assert {:ok, first} = Embedplay.open_movie(context.movie)

    :sys.replace_state(Sessions, fn state ->
      put_in(state.sessions[first.session_id].created_at, System.monotonic_time(:second) - 601)
    end)

    assert {:ok, second} = Embedplay.open_movie(context.movie)
    refute first.session_id == second.session_id

    assert {:ok, %{status: 200}} =
             Embedplay.fetch_resource(first.session_id, first.resource_id, context.movie.id,
               method: :head
             )

    :sys.replace_state(Sessions, fn state ->
      put_in(state.sessions[first.session_id].touched_at, System.monotonic_time(:second) - 1801)
    end)

    send(Sessions, :cleanup)

    assert {:error, :resource_not_found} =
             Embedplay.fetch_resource(first.session_id, first.resource_id, context.movie.id,
               method: :head
             )

    assert {:ok, %{status: 200}} =
             Embedplay.fetch_resource(second.session_id, second.resource_id, context.movie.id,
               method: :head
             )
  end

  test "upstream HTML masquerading as a media resource is served inertly", context do
    Req.Test.stub(__MODULE__, &fixture_response/1)
    master = get(context.conn, context.master)

    media_path =
      master.resp_body |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "/api/"))

    media = get(build_conn(), media_path)

    segment_path =
      media.resp_body |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "/api/"))

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> put_resp_header("content-type", "text/html")
      |> send_resp(200, "<script>alert(1)</script>")
    end)

    segment = get(build_conn(), segment_path)
    assert get_resp_header(segment, "content-type") == ["application/octet-stream"]
    assert get_resp_header(segment, "content-security-policy") == ["default-src 'none'; sandbox"]
    assert get_resp_header(segment, "x-content-type-options") == ["nosniff"]
  end

  test "a resolver on the new contract still serves HLS from the master URL", context do
    Req.Test.stub(__MODULE__, fn
      %{request_path: "/resolve"} = conn ->
        url = "https://93.184.216.34/root/master.m3u8?signed=a%2Fb"
        Req.Test.json(conn, %{kind: "hls", media_url: url, manifest_url: url, headers: %{}})

      conn ->
        fixture_response(conn)
    end)

    master = get(context.conn, context.master)
    assert master.status == 200
    assert get_resp_header(master, "content-type") == ["application/vnd.apple.mpegurl"]
    assert master.resp_body =~ ~r{^/api/stream/embedplay/[^/]+/[^/]+\.m3u8\?token=}m
  end

  test "an outdated resolver adapter is a distinct, retryable 503 on both routes", context do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(502, ~s({"error":{"code":"unsupported_page"}}))
    end)

    for path <- [context.master, video_path(context.token)] do
      response = get(build_conn(), path)
      assert response.status == 503
      assert json_response(response, 503)["error"]["code"] == "resolver_outdated"
    end
  end

  describe "progressive MP4 on video.mp4" do
    setup context do
      owner = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(owner, {:upstream, conn.host, conn.request_path, conn.req_headers})
        mp4_response(conn)
      end)

      %{video: video_path(context.token)}
    end

    test "HEAD names the format without resolving", %{video: video} do
      response = head(build_conn(), video)

      assert response.status == 200
      assert response.resp_body == ""
      assert get_resp_header(response, "content-type") == ["video/mp4"]
      assert get_resp_header(response, "accept-ranges") == ["bytes"]
      assert get_resp_header(response, "access-control-allow-origin") == ["*"]
      refute_received {:upstream, _host, _path, _headers}
    end

    test "GET without Range streams the whole file as 200, never 206", %{video: video} do
      response = get(build_conn(), video)

      assert response.status == 200
      assert response.resp_body == @movie_bytes
      assert binary_part(response.resp_body, 4, 4) == "ftyp"
      assert get_resp_header(response, "content-type") == ["video/mp4"]
      assert get_resp_header(response, "content-length") == ["#{byte_size(@movie_bytes)}"]
      assert get_resp_header(response, "content-range") == []
      assert get_resp_header(response, "cache-control") == ["private, no-store, no-transform"]
      assert get_resp_header(response, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(response, "connection") == ["close"]

      assert_received {:upstream, "127.0.0.1", "/resolve", _headers}

      # Both hops carry the resolver's headers, no Range was invented, and no
      # Origin is ever added (the source answers an Origin with 404).
      for {host, path} <- [{"93.184.216.34", "/sora/123/token"}, {"104.16.0.1", "/t/movie.mp4"}] do
        assert_received {:upstream, ^host, ^path, headers}
        assert {"referer", "https://abysscdn.com/"} in headers
        assert {"user-agent", "Mozilla/5.0 Test"} in headers
        refute List.keymember?(headers, "range", 0)
        refute List.keymember?(headers, "origin", 0)
      end
    end

    test "GET with Range forwards it unchanged and passes 206 and Content-Range through",
         %{video: video} do
      size = byte_size(@movie_bytes)

      for {range, first, last} <- [
            {"bytes=4-7", 4, 7},
            {"bytes=0-", 0, size - 1},
            {"bytes=60-", 60, size - 1},
            {"bytes=-4", size - 4, size - 1},
            {"bytes=10-1000", 10, size - 1}
          ] do
        response = build_conn() |> put_req_header("range", range) |> get(video)

        assert response.status == 206, "#{range} answered #{response.status}"
        assert response.resp_body == binary_part(@movie_bytes, first, last - first + 1)
        assert get_resp_header(response, "content-range") == ["bytes #{first}-#{last}/#{size}"]
        assert get_resp_header(response, "content-length") == ["#{last - first + 1}"]
        assert get_resp_header(response, "accept-ranges") == ["bytes"]

        for host <- ["93.184.216.34", "104.16.0.1"] do
          assert_received {:upstream, ^host, _path, headers}
          assert {"range", range} in headers
        end
      end

      # Every range after the first start reused the one resolution.
      assert_received {:upstream, "127.0.0.1", "/resolve", _headers}
      refute_received {:upstream, "127.0.0.1", "/resolve", _headers}
    end

    test "multi-range requests are rejected", %{video: video} do
      response = build_conn() |> put_req_header("range", "bytes=0-1,4-5") |> get(video)
      assert response.status == 416
      refute_received {:upstream, "104.16.0.1", _path, _headers}
    end

    test "an upstream 206 to a request that carried no Range is refused", %{video: video} do
      Req.Test.stub(__MODULE__, fn
        %{host: "104.16.0.1"} = conn ->
          conn
          |> put_resp_header("content-range", "bytes 0-3/64")
          |> send_resp(206, "abcd")

        conn ->
          mp4_response(conn)
      end)

      response = get(build_conn(), video)
      assert response.status == 502
      refute response.resp_body =~ "abcd"
    end

    test "upstream 403 on a later range invalidates the session and asks for a restart",
         context do
      first = build_conn() |> put_req_header("range", "bytes=0-3") |> get(context.video)
      assert first.status == 206

      # The source host answers a challenge page once the resolution expires.
      Req.Test.expect(__MODULE__, &send_resp(&1, 403, "cloudflare challenge"))

      response = build_conn() |> put_req_header("range", "bytes=10-") |> get(context.video)
      assert response.status == 409
      assert json_response(response, 409)["error"]["code"] == "playback_restart_required"

      # The old resolution is gone, so the next request resolves afresh.
      next = build_conn() |> put_req_header("range", "bytes=10-") |> get(context.video)
      assert next.status == 206
      assert resolutions() == 2
    end

    test "a start from byte 0 on a stale cached source renews within the same request",
         context do
      assert get(build_conn(), context.video).status == 200

      Req.Test.expect(__MODULE__, &send_resp(&1, 403, "expired upstream token"))

      response = get(build_conn(), context.video)
      assert response.status == 200
      assert response.resp_body == @movie_bytes
      assert resolutions() == 2
    end

    test "an MP4 session outlives the new-start TTL while alive; idle cleanup releases it",
         context do
      alias Streamix.Embedplay.Sessions

      assert {:ok, %{kind: :mp4} = first} = Embedplay.open_movie(context.movie)
      assert first.resource_id =~ ~r/\.mp4$/

      :sys.replace_state(Sessions, fn state ->
        put_in(state.sessions[first.session_id].created_at, System.monotonic_time(:second) - 601)
      end)

      # Every range of a progressive playback opens the movie again, so a new
      # resolution here would move a playing viewer to another source.
      assert {:ok, ^first} = Embedplay.open_movie(context.movie)

      :sys.replace_state(Sessions, fn state ->
        put_in(state.sessions[first.session_id].touched_at, System.monotonic_time(:second) - 1801)
      end)

      # A long transfer reports activity, which keeps the session alive.
      Sessions.touch(first.session_id)
      assert {:ok, ^first} = Embedplay.open_movie(context.movie)

      :sys.replace_state(Sessions, fn state ->
        put_in(state.sessions[first.session_id].touched_at, System.monotonic_time(:second) - 1801)
      end)

      send(Sessions, :cleanup)
      assert {:ok, second} = Embedplay.open_movie(context.movie)
      refute second.session_id == first.session_id
      assert resolutions() == 2
    end

    test "the progressive root is never served by the buffered resource route", context do
      assert {:ok, session} = Embedplay.open_movie(context.movie)

      assert {:error, :resource_not_found} =
               Embedplay.fetch_resource(session.session_id, session.resource_id, context.movie.id)

      path =
        "/api/stream/embedplay/#{session.session_id}/#{session.resource_id}?token=#{context.token}"

      assert get(build_conn(), path).status == 404
      refute_received {:upstream, "104.16.0.1", _path, _headers}
    end

    test "the HLS master route refuses an MP4 session instead of cross-serving it", context do
      response = get(build_conn(), context.master)

      assert response.status == 409
      assert json_response(response, 409)["error"]["code"] == "stream_format_mismatch"
      refute_received {:upstream, "104.16.0.1", _path, _headers}
    end
  end

  test "the MP4 route refuses an HLS session instead of cross-serving it", context do
    Req.Test.stub(__MODULE__, &fixture_response/1)

    response = get(build_conn(), video_path(context.token))
    assert response.status == 409
    assert json_response(response, 409)["error"]["code"] == "stream_format_mismatch"
  end

  describe "minted EmbedPlay URLs" do
    test "catalog, watch page and generic proxy all point at the MP4 route", context do
      for url <- [
            StreamUrls.signed_movie_url(context.movie),
            StreamUrls.browser_movie_url(context.movie)
          ] do
        assert url =~ "/api/stream/embedplay/video.mp4?token="
        refute url =~ ".m3u8"
      end

      assert {:ok, "/api/stream/embedplay/video.mp4?token=" <> _token} =
               PlayerHelpers.resolve_stream_url(
                 "movie",
                 context.movie,
                 context.movie.provider,
                 nil
               )

      proxied = get(build_conn(), "/api/stream/proxy?token=#{context.token}")
      assert redirected_to(proxied) == video_path(context.token)
    end

    test "imported movies hint progressive playback to the web player", context do
      assert context.movie.container_extension == "mp4"

      assert Metadata.stream_type_hint(:movie, context.movie, :embedplay) == "mp4"
    end
  end

  defp video_path(token),
    do: "/api/stream/embedplay/video.mp4?token=#{URI.encode_www_form(token)}"

  # Counts (and drains) the resolver calls reported by the stub so far.
  defp resolutions(count \\ 0) do
    receive do
      {:upstream, _host, "/resolve", _headers} -> resolutions(count + 1)
    after
      0 -> count
    end
  end

  defp mp4_response(%{request_path: "/resolve"} = conn) do
    Req.Test.json(conn, %{
      kind: "mp4",
      media_url: "https://93.184.216.34/sora/123/token",
      expires_at: nil,
      headers: %{"referer" => "https://abysscdn.com/", "user-agent" => "Mozilla/5.0 Test"}
    })
  end

  # The source host checks the Referer and redirects to an ephemeral tunnel.
  defp mp4_response(%{host: "93.184.216.34", request_path: "/sora/123/token"} = conn) do
    conn
    |> put_resp_header("location", "https://104.16.0.1/t/movie.mp4")
    |> send_resp(302, "")
  end

  defp mp4_response(%{host: "104.16.0.1", request_path: "/t/movie.mp4"} = conn) do
    size = byte_size(@movie_bytes)
    conn = put_resp_header(conn, "content-type", "video/mp4")

    case get_req_header(conn, "range") do
      [] ->
        conn
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header("content-length", "#{size}")
        |> send_resp(200, @movie_bytes)

      ["bytes=" <> spec] ->
        {first, last} =
          case String.split(spec, "-") do
            ["", suffix] -> {max(size - String.to_integer(suffix), 0), size - 1}
            [first, ""] -> {String.to_integer(first), size - 1}
            [first, last] -> {String.to_integer(first), min(String.to_integer(last), size - 1)}
          end

        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> put_resp_header("content-length", "#{last - first + 1}")
        |> send_resp(206, binary_part(@movie_bytes, first, last - first + 1))
    end
  end

  defp fixture_response(%{request_path: "/resolve"} = conn) do
    Req.Test.json(conn, %{
      manifest_url: "https://93.184.216.34/root/master.m3u8?signed=a%2Fb",
      expires_at: nil,
      headers: %{}
    })
  end

  defp fixture_response(%{request_path: "/root/master.m3u8"} = conn) do
    send_resp(
      conn,
      200,
      "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nvideo.m3u8?signature=x%2By\n"
    )
  end

  defp fixture_response(%{request_path: "/root/video.m3u8"} = conn) do
    send_resp(
      conn,
      200,
      "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"/key?key=one\"\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:6,\nsegment.ts?piece=1%2F2\n#EXT-X-ENDLIST\n"
    )
  end

  defp fixture_response(%{request_path: "/key"} = conn),
    do: send_resp(conn, 200, "0123456789abcdef")

  defp fixture_response(%{request_path: "/root/init.mp4"} = conn),
    do: send_resp(conn, 200, "init")

  defp fixture_response(%{request_path: "/root/segment.ts"} = conn) do
    conn
    |> put_resp_header("content-range", "bytes 2-4/10")
    |> put_resp_header("content-type", "video/mp2t")
    |> send_resp(206, "234")
  end
end
