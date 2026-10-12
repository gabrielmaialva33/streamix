defmodule StreamixWeb.XtreamHlsControllerTest do
  use StreamixWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv.{Episode, Season}
  alias Streamix.Iptv.Streaming.XtreamHls.Sessions
  alias Streamix.{Providers, Repo}
  alias StreamixWeb.Catalog.StreamUrls
  alias StreamixWeb.Endpoint
  alias StreamixWeb.PlayerHelpers
  alias StreamixWeb.StreamToken

  # Distinctive credentials, so a leak anywhere is unmistakable.
  @user "megauser"
  @pass "s3cr3t-Pa55word"
  @panel "93.184.216.34"
  @master_host "104.16.0.1"
  @cdn_host "104.16.0.2"

  # Two MPEG-TS packets: the sync byte opens each 188-byte packet.
  @ts_segment <<0x47>> <> :binary.copy(<<0>>, 187) <> <<0x47>> <> :binary.copy(<<1>>, 187)

  setup do
    original = Application.get_env(:streamix, :xtream_hls, [])
    original_keys = Application.get_env(:streamix, :api_keys, [])

    Application.put_env(:streamix, :xtream_hls,
      http_options: [plug: {Req.Test, __MODULE__}],
      lease_wait_ms: 50
    )

    Req.Test.set_req_test_to_shared()

    on_exit(fn ->
      Application.put_env(:streamix, :xtream_hls, original)
      Application.put_env(:streamix, :api_keys, original_keys)
    end)

    provider =
      global_provider_fixture(%{url: "http://#{@panel}", username: @user, password: @pass})

    movie = movie_fixture(provider, %{container_extension: "m3u8", stream_id: 777})
    token = StreamToken.sign_movie(movie.id, nil, bypass_subscription: true)

    %{provider: provider, movie: movie, token: token, master: master_path(token)}
  end

  describe "master and resources" do
    setup do
      owner = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(
          owner,
          {:upstream, conn.host, conn.request_path, conn.query_string, conn.req_headers}
        )

        upstream(conn)
      end)

      :ok
    end

    test "HEAD authorizes and advertises HLS without an upstream request", %{master: master} do
      response = head(build_conn(), master)

      assert response.status == 200
      assert response.resp_body == ""

      assert get_resp_header(response, "content-type") == [
               "application/vnd.apple.mpegurl; charset=utf-8"
             ]

      refute_received {:upstream, _host, _path, _query, _headers}
    end

    test "the master follows its redirect and rewrites renditions and variants", context do
      response = get(build_conn(), context.master)

      assert response.status == 200
      assert get_resp_header(response, "content-type") == ["application/vnd.apple.mpegurl"]
      assert get_resp_header(response, "access-control-allow-origin") == ["*"]
      assert get_resp_header(response, "cache-control") == ["private, no-store"]

      body = response.resp_body
      assert body =~ "#EXT-X-VERSION:4"
      assert body =~ ~s(NAME="Português")
      refute_upstream_leak(response)

      # The panel URL carries the credentials and the honest provider UA.
      assert_received {:upstream, @panel, "/movie/megauser/s3cr3t-Pa55word/777.m3u8", "", headers}

      assert {"user-agent", "IPTVSmartersPlayer"} in headers
      assert_received {:upstream, @master_host, "/hls/master.m3u8", "token=abc", _headers}

      # Both audio renditions and both variants became opaque playlist URLs.
      assert length(Regex.scan(~r{URI="/api/stream/hls/[^/"]+/[^/"]+\.m3u8\?token=}, body)) == 2
      assert length(Regex.scan(~r{^/api/stream/hls/[^/]+/[^/]+\.m3u8\?token=}m, body)) == 2
    end

    test "variants, keys and segments resolve relative and absolute references",
         context do
      master = get(build_conn(), context.master).resp_body
      [hd_variant, sd_variant] = lines(master)
      [pt_audio, en_audio] = uri_attributes(master)

      # A `text/plain` variant is still a playlist: its role decides.
      variant = get(build_conn(), hd_variant)
      assert variant.status == 200
      assert get_resp_header(variant, "content-type") == ["application/vnd.apple.mpegurl"]
      refute_upstream_leak(variant)
      assert_received {:upstream, @cdn_host, "/v/720/index.m3u8", "sig=x%2By", _headers}

      for path <- [sd_variant, pt_audio, en_audio] do
        assert get(build_conn(), path).status == 200
      end

      # Relative to the master's final URL, not to the panel URL.
      assert_received {:upstream, @master_host, "/hls/360/index.m3u8", "", _headers}
      assert_received {:upstream, @master_host, "/hls/audio_en.m3u8", "", _headers}
      assert_received {:upstream, @cdn_host, "/v/audio_pt.m3u8", "sig=a%2Bb", _headers}

      [key] = uri_attributes(variant.resp_body)
      [first_segment, second_segment] = lines(variant.resp_body)

      # Known media extensions survive; a disguised `.js` segment does not.
      assert first_segment =~ ~r{/[^/]+\.ts\?token=}
      assert second_segment =~ ~r{/[^/]+\.bin\?token=}

      assert get(build_conn(), key).resp_body == "0123456789abcdef"
      assert_received {:upstream, @cdn_host, "/keys/k1", "", _headers}

      # MPEG-TS served as `application/javascript` is relabelled by content.
      for path <- [first_segment, second_segment] do
        segment = get(build_conn(), path)
        assert segment.status == 200
        assert segment.resp_body == @ts_segment
        assert get_resp_header(segment, "content-type") == ["video/mp2t"]
        assert get_resp_header(segment, "x-content-type-options") == ["nosniff"]
      end

      assert_received {:upstream, @cdn_host, "/v/720/seg-00001.ts", "t=1", _headers}
      assert_received {:upstream, "104.16.0.3", "/c/seg-00002.js", "", _headers}

      ranged = build_conn() |> put_req_header("range", "bytes=0-187") |> get(first_segment)
      assert ranged.status == 206
      assert get_resp_header(ranged, "content-range") == ["bytes 0-187/376"]
      assert_received {:upstream, @cdn_host, "/v/720/seg-00001.ts", "t=1", headers}
      assert {"range", "bytes=0-187"} in headers
    end

    test "behind the browser stream proxy every reference stays behind it", context do
      proxied = get(build_conn(), master_path(context.token) <> "&edge=1")
      assert proxied.status == 200

      [variant | _] = lines(proxied.resp_body)
      assert String.starts_with?(variant, "https://source.mahina.fun/proxy?url=")

      inner = variant |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.get("url")
      assert inner =~ ~r{^https?://[^/]+/api/stream/hls/[^/]+/[^/]+\.m3u8\?token=.+&edge=1$}
      refute_upstream_leak(proxied)

      # The proxy hands the inner URL back to this origin; its playlist is
      # wrapped the same way.
      nested = get(build_conn(), URI.parse(inner) |> then(&"#{&1.path}?#{&1.query}"))
      assert [segment | _] = lines(nested.resp_body)
      assert String.starts_with?(segment, "https://source.mahina.fun/proxy?url=")
    end

    test "an upstream 403 on a segment invalidates the session", context do
      master = get(build_conn(), context.master).resp_body
      [variant | _] = lines(master)
      [segment | _] = lines(get(build_conn(), variant).resp_body)

      Req.Test.stub(__MODULE__, &send_resp(&1, 403, "expired cdn token"))

      response = get(build_conn(), segment)
      assert response.status == 409
      assert json_response(response, 409)["error"]["code"] == "playback_restart_required"

      assert get(build_conn(), variant).status == 404
    end

    test "a playing session outlives the two-hour start window of its token", context do
      old =
        Phoenix.Token.sign(
          Endpoint,
          "stream",
          %{type: "movie", id: context.movie.id, user_id: nil, bypass: true},
          signed_at: System.system_time(:second) - 3 * 3_600
        )

      # The session was opened while the token was fresh.
      [variant | _] = lines(get(build_conn(), context.master).resp_body)
      aged = String.replace(variant, encoded(context.token), encoded(old))

      assert get(build_conn(), aged).status == 200

      # A new start with the old token is refused.
      response = get(build_conn(), master_path(old))
      assert json_response(response, 401)["error"]["code"] == "token_expired"
    end

    test "a resource is served only to a token for the same item", context do
      [variant | _] = lines(get(build_conn(), context.master).resp_body)

      other = movie_fixture(context.provider, %{container_extension: "m3u8"})
      other_token = StreamToken.sign_movie(other.id, nil, bypass_subscription: true)

      response =
        get(build_conn(), String.replace(variant, encoded(context.token), encoded(other_token)))

      assert response.status == 404
      assert json_response(response, 404)["error"]["code"] == "resource_not_found"
    end
  end

  test "credentials never reach a response body, header or log line", context do
    Req.Test.stub(__MODULE__, &upstream/1)

    log =
      capture_log([level: :debug], fn ->
        master = get(build_conn(), context.master)
        refute_upstream_leak(master)

        for path <- lines(master.resp_body) ++ uri_attributes(master.resp_body) do
          playlist = get(build_conn(), path)
          refute_upstream_leak(playlist)

          for child <- lines(playlist.resp_body) ++ uri_attributes(playlist.resp_body) do
            refute_upstream_leak(get(build_conn(), child))
          end
        end

        # Failures log too; they must not carry the URL either.
        Req.Test.stub(__MODULE__, &send_resp(&1, 404, "No playable stream found."))
        refute_upstream_leak(get(build_conn(), context.master))
      end)

    refute log =~ @pass
    refute log =~ @user
  end

  test "a dead item's 404 surfaces as upstream_not_found, not a timeout or a clip", context do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(404, "No playable stream found.")
    end)

    capture_log(fn ->
      response = get(build_conn(), context.master)

      assert response.status == 404
      assert json_response(response, 404)["error"]["code"] == "upstream_not_found"
      refute response.resp_body =~ "No playable stream"
    end)
  end

  test "every redirect hop is SSRF-checked before it is requested", context do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:upstream, conn.host})

      conn
      |> put_resp_header("location", "http://127.0.0.1/internal/master.m3u8")
      |> send_resp(302, "")
    end)

    response = get(build_conn(), context.master)
    assert response.status == 403
    assert json_response(response, 403)["error"]["code"] == "unsafe_url"
    assert_received {:upstream, @panel}
    refute_received {:upstream, "127.0.0.1"}
  end

  test "a playlist reference to a private address is refused when fetched", context do
    Req.Test.stub(__MODULE__, fn
      %{host: @panel} = conn ->
        send_resp(conn, 200, "#EXTM3U\n#EXTINF:6,\nhttp://10.0.0.7/segment.ts\n#EXT-X-ENDLIST\n")
    end)

    [segment] = lines(get(build_conn(), context.master).resp_body)
    response = get(build_conn(), segment)

    assert response.status == 403
    assert json_response(response, 403)["error"]["code"] == "unsafe_url"
  end

  describe "authorization" do
    test "missing, invalid, expired and non-entitled tokens are refused", context do
      assert json_response(get(build_conn(), "/api/stream/hls/master.m3u8"), 400)["error"][
               "code"
             ] == "missing_token"

      assert get(build_conn(), master_path("bad")).status == 401

      expired =
        Phoenix.Token.sign(
          Endpoint,
          "stream",
          %{type: "movie", id: context.movie.id, user_id: nil, bypass: true},
          signed_at: System.system_time(:second) - 7_300
        )

      response = get(build_conn(), master_path(expired))
      assert json_response(response, 401)["error"]["code"] == "token_expired"

      # A global item needs a subscription unless the token or the request
      # carries the integration bypass.
      unentitled = StreamToken.sign_movie(context.movie.id, nil)
      response = get(build_conn(), master_path(unentitled))
      assert json_response(response, 403)["error"]["code"] == "subscription_required"

      Application.put_env(:streamix, :api_keys, ["hls-test-key"])

      response =
        build_conn()
        |> put_req_header("x-api-key", "hls-test-key")
        |> head(master_path(unentitled))

      assert response.status == 200
    end

    test "a private provider's item plays only for its owner" do
      owner = user_fixture()
      stranger = user_fixture()
      provider = provider_fixture(owner, %{url: "http://#{@panel}"})
      movie = movie_fixture(provider, %{container_extension: "m3u8"})

      assert head(build_conn(), master_path(StreamToken.sign_movie(movie.id, owner.id))).status ==
               200

      response = get(build_conn(), master_path(StreamToken.sign_movie(movie.id, stranger.id)))
      assert json_response(response, 403)["error"]["code"] == "token_unauthorized"
    end

    test "inactive and degraded providers refuse playback without an upstream request",
         context do
      owner = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(owner, :upstream)
        upstream(conn)
      end)

      {:ok, _} = Providers.update_provider(context.provider, %{is_active: false})
      response = get(build_conn(), context.master)
      assert json_response(response, 503)["error"]["code"] == "provider_disabled"

      context.provider
      |> Ecto.Changeset.change(is_active: true, health_status: :degraded)
      |> Repo.update!()

      for request <- [&get/2, &head/2] do
        response = request.(build_conn(), context.master)
        assert response.status == 503
        assert get_resp_header(response, "access-control-allow-origin") == ["*"]
      end

      refute_received :upstream
    end

    test "a progressive item is refused instead of cross-served", context do
      movie = movie_fixture(context.provider, %{container_extension: "mp4"})
      token = StreamToken.sign_movie(movie.id, nil, bypass_subscription: true)

      response = get(build_conn(), master_path(token))
      assert json_response(response, 409)["error"]["code"] == "stream_format_mismatch"
    end
  end

  describe "leases" do
    test "fetches beyond the per-provider cap wait, then fail cleanly", context do
      Application.put_env(:streamix, :xtream_hls,
        http_options: [plug: {Req.Test, __MODULE__}],
        lease_wait_ms: 50,
        max_fetches_per_provider: 1
      )

      Req.Test.stub(__MODULE__, &upstream/1)
      {:ok, lease} = Sessions.acquire(context.provider.id)

      response = get(build_conn(), context.master)
      assert json_response(response, 503)["error"]["code"] == "provider_capacity_exhausted"

      Sessions.release(lease)
      assert get(build_conn(), context.master).status == 200
    end
  end

  describe "episodes" do
    test "an m3u8 episode plays through the gateway from the series path", context do
      episode = episode_fixture(context.provider, "m3u8")
      token = StreamToken.sign_episode(episode.id, nil, bypass_subscription: true)
      owner = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(owner, {:upstream, conn.request_path})
        send_resp(conn, 200, "#EXTM3U\n#EXTINF:6,\nseg.ts\n#EXT-X-ENDLIST\n")
      end)

      response = get(build_conn(), master_path(token))
      assert response.status == 200
      assert_received {:upstream, path}
      assert path == "/series/megauser/s3cr3t-Pa55word/#{episode.episode_id}.m3u8"

      assert StreamUrls.signed_episode_url(Repo.preload(episode, season: [series: :provider])) =~
               "/api/stream/hls/master.m3u8?token="
    end
  end

  describe "minted URLs" do
    test "m3u8 items point at the gateway with an .m3u8 suffix on every surface", context do
      signed = StreamUrls.signed_movie_url(Repo.preload(context.movie, :provider))
      assert signed =~ ~r{/api/stream/hls/master\.m3u8\?token=[^&]+$}

      browser = StreamUrls.browser_movie_url(Repo.preload(context.movie, :provider))
      assert String.starts_with?(browser, "https://source.mahina.fun/proxy?url=")
      inner = browser |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.get("url")
      assert inner =~ ~r{/api/stream/hls/master\.m3u8\?token=.+&edge=1$}

      assert {:ok, watch} =
               PlayerHelpers.resolve_stream_url("movie", context.movie, context.provider, nil)

      assert watch =~ "/api/stream/hls/master.m3u8?token="

      # Players holding an older token-proxy URL are redirected.
      proxied = get(build_conn(), "/api/stream/proxy?token=#{encoded(context.token)}")
      assert redirected_to(proxied) == master_path(context.token)

      Application.put_env(:streamix, :api_keys, ["hls-test-key"])

      api =
        build_conn()
        |> put_req_header("x-api-key", "hls-test-key")
        |> get("/api/v1/catalog/movies/#{context.movie.id}/stream")

      assert json_response(api, 200)["data"]["stream_url"] =~ "/api/stream/hls/master.m3u8?token="
    end

    test "mp4 items keep the progressive token proxy", context do
      movie =
        context.provider
        |> movie_fixture(%{container_extension: "mp4"})
        |> Repo.preload(:provider)

      assert StreamUrls.signed_movie_url(movie) =~ "/api/stream/proxy?token="
      refute StreamUrls.signed_movie_url(movie) =~ ".m3u8"
      assert StreamUrls.browser_movie_url(movie) =~ "proxy%3Ftoken%3D"

      assert {:ok, url} = PlayerHelpers.resolve_stream_url("movie", movie, context.provider, nil)
      assert url =~ "/api/stream/proxy?token="
    end
  end

  defp master_path(token), do: "/api/stream/hls/master.m3u8?token=#{encoded(token)}"
  defp encoded(token), do: URI.encode_www_form(token)

  defp lines(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  defp uri_attributes(body), do: Regex.scan(~r/URI="([^"]+)"/, body) |> Enum.map(&List.last/1)

  defp refute_upstream_leak(response) do
    exposed = [response.resp_body | Enum.map(response.resp_headers, &elem(&1, 1))]

    for value <- exposed,
        secret <- [@user, @pass, @panel, @master_host, @cdn_host, "token=abc"] do
      refute value =~ secret, "#{inspect(secret)} leaked into #{inspect(value)}"
    end
  end

  defp episode_fixture(provider, extension) do
    series = series_content_fixture(provider)

    season =
      %Season{}
      |> Season.changeset(%{season_number: 1, name: "T1", series_id: series.id})
      |> Repo.insert!()

    catalog_item = catalog_item_fixture("episode", provider.id)

    %Episode{}
    |> Episode.changeset(%{
      episode_id: System.unique_integer([:positive]),
      episode_num: 1,
      title: "S01E01",
      container_extension: extension,
      season_id: season.id
    })
    |> Ecto.Changeset.put_change(:catalog_item_id, catalog_item.id)
    |> Repo.insert!()
  end

  # The panel redirects once to a master on another host; variants, audio,
  # keys and segments live on a CDN that labels everything wrongly.
  defp upstream(%{host: @panel, request_path: "/movie/megauser/s3cr3t-Pa55word/777.m3u8"} = conn) do
    conn
    |> put_resp_header("location", "https://#{@master_host}/hls/master.m3u8?token=abc")
    |> send_resp(302, "")
  end

  defp upstream(%{host: @master_host, request_path: "/hls/master.m3u8"} = conn) do
    conn
    |> put_resp_content_type("application/vnd.apple.mpegurl", nil)
    |> send_resp(200, """
    #EXTM3U
    #EXT-X-VERSION:4
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Português",LANGUAGE="pt",DEFAULT=YES,URI="https://#{@cdn_host}/v/audio_pt.m3u8?sig=a%2Bb"
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",URI="audio_en.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,AUDIO="aud"
    https://#{@cdn_host}/v/720/index.m3u8?sig=x%2By
    #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,AUDIO="aud"
    360/index.m3u8
    """)
  end

  defp upstream(%{request_path: "/v/720/index.m3u8"} = conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, """
    #EXTM3U
    #EXT-X-TARGETDURATION:6
    #EXT-X-KEY:METHOD=AES-128,URI="/keys/k1"
    #EXTINF:6.0,
    seg-00001.ts?t=1
    #EXTINF:6.0,
    https://104.16.0.3/c/seg-00002.js
    #EXT-X-ENDLIST
    """)
  end

  defp upstream(%{request_path: path} = conn)
       when path in ["/hls/360/index.m3u8", "/hls/audio_en.m3u8", "/v/audio_pt.m3u8"] do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "#EXTM3U\n#EXTINF:6.0,\nseg.ts\n#EXT-X-ENDLIST\n")
  end

  defp upstream(%{request_path: "/keys/k1"} = conn), do: send_resp(conn, 200, "0123456789abcdef")

  defp upstream(%{request_path: path} = conn) do
    if String.ends_with?(path, [".ts", ".js"]),
      do: segment(conn),
      else: send_resp(conn, 404, "not found")
  end

  defp segment(conn) do
    conn = put_resp_content_type(conn, "application/javascript")

    case get_req_header(conn, "range") do
      ["bytes=0-187"] ->
        conn
        |> put_resp_header("content-range", "bytes 0-187/376")
        |> send_resp(206, binary_part(@ts_segment, 0, 188))

      [] ->
        send_resp(conn, 200, @ts_segment)
    end
  end
end
