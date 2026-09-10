defmodule StreamixWeb.EmbedplayStreamControllerTest do
  use StreamixWeb.ConnCase, async: false

  alias Streamix.{Catalog, Embedplay, Providers}
  alias StreamixWeb.{Endpoint, StreamToken}

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
