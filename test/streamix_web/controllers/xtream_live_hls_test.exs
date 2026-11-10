defmodule StreamixWeb.XtreamLiveHlsTest do
  @moduledoc false
  use StreamixWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Streamix.IptvFixtures

  alias Streamix.Hls.{Registry, SegmentCache}
  alias Streamix.Iptv.Streaming.XtreamHls.Sessions
  alias Streamix.Repo
  alias StreamixWeb.Catalog.StreamUrls
  alias StreamixWeb.Endpoint
  alias StreamixWeb.PlayerComponents.Metadata
  alias StreamixWeb.PlayerHelpers
  alias StreamixWeb.StreamToken

  @user "megauser"
  @pass "s3cr3t-Pa55word"
  @panel "93.184.216.34"
  @cdn "104.16.3.3"
  @ts_segment <<0x47>> <> :binary.copy(<<0>>, 187) <> <<0x47>> <> :binary.copy(<<1>>, 187)

  setup do
    originals =
      for key <- [:xtream_hls, :xtream_delivery, :api_keys],
          do: {key, Application.get_env(:streamix, key)}

    stub = [http_options: [plug: {Req.Test, __MODULE__}]]
    Application.put_env(:streamix, :xtream_hls, stub ++ [live_prefetch_segments: 0])
    Application.put_env(:streamix, :xtream_delivery, stub)
    Req.Test.set_req_test_to_shared()
    :ok = SegmentCache.flush()

    on_exit(fn ->
      for {key, value} <- originals, do: Application.put_env(:streamix, key, value || [])
    end)

    provider =
      global_provider_fixture(%{
        url: "http://#{@panel}",
        username: @user,
        password: @pass,
        probe_live_delivery: true
      })

    channel = provider |> channel_fixture(%{stream_id: 501}) |> Repo.preload(:provider)
    token = StreamToken.sign_channel(channel.id, nil, bypass_subscription: true)
    {:ok, sequence} = Agent.start_link(fn -> 4_209 end)
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:upstream, conn.request_path})
      upstream(conn, sequence)
    end)

    %{
      provider: provider,
      channel: channel,
      token: token,
      sequence: sequence,
      master: master_path(token)
    }
  end

  test "a channel whose live answers HLS is minted an .m3u8 gateway URL everywhere", context do
    signed = StreamUrls.signed_channel_url(context.channel)
    assert signed =~ ~r{/api/stream/hls/master\.m3u8\?token=[^&]+$}

    browser = StreamUrls.browser_channel_url(context.channel)
    assert String.starts_with?(browser, "https://source.mahina.fun/proxy?url=")
    assert URI.decode_www_form(browser) =~ "/api/stream/hls/master.m3u8?token="
    assert URI.decode_www_form(browser) =~ "&edge=1"

    assert {:ok, watch} =
             PlayerHelpers.resolve_stream_url(
               "live_channel",
               context.channel,
               context.provider,
               nil
             )

    assert watch =~ "/api/stream/hls/master.m3u8?token="

    # The player gets an HLS engine although live defaults to a TS hint.
    assert Metadata.stream_type(watch, :live_channel, context.channel, "xtream") == "m3u8"

    proxied = get(build_conn(), "/api/stream/proxy?token=#{encoded(context.token)}")
    assert redirected_to(proxied) == context.master

    Application.put_env(:streamix, :api_keys, ["live-test-key"])

    api =
      build_conn()
      |> put_req_header("x-api-key", "live-test-key")
      |> get("/api/v1/catalog/channels/#{context.channel.id}/stream")

    assert json_response(api, 200)["data"]["stream_url"] =~ "/api/stream/hls/master.m3u8?token="

    # One probe served every surface.
    assert probes() == 1
  end

  test "each refresh is fetched upstream and rewritten as the sequence advances", context do
    master = get(build_conn(), context.master)
    assert master.status == 200
    assert master.resp_body =~ "#EXT-X-STREAM-INF:BANDWIDTH=3000000\n"
    [live] = lines(master.resp_body)
    assert live =~ ~r{^/api/stream/hls/[^/]+/[^/]+\.m3u8\?token=}

    # The probe's final hop and the master each fetched the playlist once.
    assert playlist_fetches() == 2

    first = get(build_conn(), live)
    assert first.status == 200
    assert get_resp_header(first, "content-type") == ["application/vnd.apple.mpegurl"]
    assert first.resp_body =~ "#EXT-X-MEDIA-SEQUENCE:4209"
    refute first.resp_body =~ "#EXT-X-ENDLIST"
    first_segments = lines(first.resp_body)
    assert length(first_segments) == 5
    refute_leak(first)

    # The immediate variant request reuses the playlist fetched for the
    # synthetic master instead of re-walking the redirect chain.
    assert playlist_fetches() == 0

    Agent.update(context.sequence, &(&1 + 2))

    second = get(build_conn(), live)
    assert second.resp_body =~ "#EXT-X-MEDIA-SEQUENCE:4211"
    second_segments = lines(second.resp_body)

    # Segments still listed keep their URLs; two new ones appear.
    assert Enum.drop(first_segments, 2) == Enum.take(second_segments, 3)
    assert length(second_segments -- first_segments) == 2

    # Subsequent refreshes reach upstream.
    assert playlist_fetches() == 1

    segment = get(build_conn(), List.last(second_segments))
    assert segment.status == 200
    assert segment.resp_body == @ts_segment
    assert get_resp_header(segment, "content-type") == ["video/mp2t"]
  end

  test "references no refresh names any more are evicted from the session", context do
    [live] = lines(get(build_conn(), context.master).resp_body)
    old = lines(get(build_conn(), live).resp_body)
    sid = session_id(live)

    # Pretend the window has passed since those references were last named.
    long_ago = System.monotonic_time(:second) - 100_000

    :sys.replace_state(Sessions, fn state ->
      update_in(state.sessions[sid].registry, fn registry ->
        %{registry | seen: Map.new(registry.seen, fn {id, _at} -> {id, long_ago} end)}
      end)
    end)

    Agent.update(context.sequence, &(&1 + 5))
    fresh = lines(get(build_conn(), live).resp_body)

    assert Enum.all?(old, &(get(build_conn(), &1).status == 404))
    assert get(build_conn(), hd(fresh)).status == 200

    # The root and the current window only.
    assert Registry.size(:sys.get_state(Sessions).sessions[sid].registry) == 1 + 5
  end

  test "viewers of one channel share a single upstream fetch per segment", context do
    owner = self()
    [live] = lines(get(build_conn(), context.master).resp_body)
    [segment | _] = lines(get(build_conn(), live).resp_body)

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:segment, self()})

      receive do
        :go -> upstream(conn, context.sequence)
      end
    end)

    viewers = for _ <- 1..4, do: Task.async(fn -> get(build_conn(), segment) end)

    assert_receive {:segment, fetch}, 1_000
    wait_for_waiters(4)
    send(fetch, :go)

    assert Enum.all?(Task.await_many(viewers), &(&1.resp_body == @ts_segment))
    refute_received {:segment, _pid}

    # A viewer arriving later is served from the cache.
    assert get(build_conn(), segment).resp_body == @ts_segment
    refute_received {:segment, _pid}
  end

  test "a channel that leads to a web page is reported unavailable, never served", context do
    channel = context.provider |> channel_fixture(%{stream_id: 123}) |> Repo.preload(:provider)
    token = StreamToken.sign_channel(channel.id, nil, bypass_subscription: true)

    capture_log(fn ->
      response = get(build_conn(), master_path(token))
      assert json_response(response, 502)["error"]["code"] == "not_a_stream"
      refute response.resp_body =~ "<html"

      # It is not minted as HLS, and the live proxy refuses it too.
      assert StreamUrls.signed_channel_url(channel) =~ "/api/stream/proxy?token="
      proxied = get(build_conn(), "/api/stream/proxy?token=#{encoded(token)}")
      assert json_response(proxied, 502)["error"]["code"] == "not_a_stream"
    end)
  end

  test "an offline channel's missing segment is a clear 404", context do
    channel = context.provider |> channel_fixture(%{stream_id: 81}) |> Repo.preload(:provider)
    token = StreamToken.sign_channel(channel.id, nil, bypass_subscription: true)

    [live] = lines(get(build_conn(), master_path(token)).resp_body)
    [segment | _] = lines(get(build_conn(), live).resp_body)

    response = get(build_conn(), segment)
    assert json_response(response, 404)["error"]["code"] == "upstream_not_found"
  end

  describe "TS live providers" do
    test "a provider without the switch keeps the live proxy, untouched, without a probe" do
      provider = global_provider_fixture(%{url: "http://#{@panel}"})
      channel = provider |> channel_fixture() |> Repo.preload(:provider)
      token = StreamToken.sign_channel(channel.id, nil, bypass_subscription: true)

      assert StreamUrls.signed_channel_url(channel) =~ "/api/stream/proxy?token="
      assert {:ok, url} = PlayerHelpers.resolve_stream_url("live_channel", channel, provider, nil)
      assert url =~ "/api/stream/proxy?token="
      assert Metadata.stream_type(url, :live_channel, channel, "xtream") == "ts"

      assert {:ok, upstream, "channel", _meta} = StreamToken.verify_and_get_url(token)
      assert upstream =~ "/live/testuser/testpass/#{channel.stream_id}.ts"

      response = get(build_conn(), master_path(token))
      assert json_response(response, 409)["error"]["code"] == "stream_format_mismatch"
      assert probes() == 0
    end

    test "a probed channel that answers TS keeps the live proxy", context do
      channel = context.provider |> channel_fixture(%{stream_id: 900}) |> Repo.preload(:provider)
      token = StreamToken.sign_channel(channel.id, nil, bypass_subscription: true)

      assert StreamUrls.signed_channel_url(channel) =~ "/api/stream/proxy?token="
      assert {:ok, _upstream, "channel", _meta} = StreamToken.verify_and_get_url(token)

      response = get(build_conn(), master_path(token))
      assert json_response(response, 409)["error"]["code"] == "stream_format_mismatch"
    end
  end

  describe "token lifetime" do
    test "a live session outlives the start window; no token is accepted forever", context do
      [live] = lines(get(build_conn(), context.master).resp_body)

      three_hours = aged_token(context.channel.id, 3 * 3_600)
      seven_hours = aged_token(context.channel.id, 7 * 3_600)

      # Playlist refreshes go through the resource route, so they keep
      # working past the two-hour start window...
      assert get(build_conn(), swap_token(live, context.token, three_hours)).status == 200

      # ...but a new start needs a fresh token, and six hours is the cap.
      response = get(build_conn(), master_path(three_hours))
      assert json_response(response, 401)["error"]["code"] == "token_expired"

      response = get(build_conn(), swap_token(live, context.token, seven_hours))
      assert json_response(response, 401)["error"]["code"] == "token_expired"
    end
  end

  test "credentials never reach a response body, header or log line", context do
    log =
      capture_log([level: :debug], fn ->
        master = get(build_conn(), context.master)
        [live] = lines(master.resp_body)
        playlist = get(build_conn(), live)
        segment = get(build_conn(), hd(lines(playlist.resp_body)))

        for response <- [master, playlist, segment], do: refute_leak(response)
      end)

    for secret <- [@user, @pass, @panel, @cdn, "cdn-token"], do: refute(log =~ secret)
  end

  describe "live startup over Bandit upstream" do
    setup do
      {:ok, sequence} = Agent.start_link(fn -> 4_209 end)
      {:ok, port} = start_bandit_upstream(self(), sequence)
      :persistent_term.put({__MODULE__, :bandit_port}, port)
      bandit_http = [adapter: __MODULE__.BanditAdapter]

      on_exit(fn -> :persistent_term.erase({__MODULE__, :bandit_port}) end)

      Application.put_env(:streamix, :xtream_hls,
        http_options: bandit_http,
        live_prefetch_segments: 1,
        live_playlist_ttl_ms: 2_000,
        live_sync_segments: 3
      )

      Application.put_env(:streamix, :xtream_delivery, http_options: bandit_http)
      :ok = SegmentCache.flush()

      provider =
        global_provider_fixture(%{
          url: "http://#{@panel}",
          username: @user,
          password: @pass,
          probe_live_delivery: true
        })

      channel = provider |> channel_fixture(%{stream_id: 501}) |> Repo.preload(:provider)
      token = StreamToken.sign_channel(channel.id, nil, bypass_subscription: true)

      %{
        provider: provider,
        channel: channel,
        token: token,
        sequence: sequence,
        port: port,
        master: master_path(token)
      }
    end

    test "reuses the synthetic master's playlist on the immediate variant request and prefetches live edge minus 3",
         context do
      master = get(build_conn(), context.master)
      assert master.status == 200
      [live] = lines(master.resp_body)
      sid = session_id(live)

      # Probe + master each walked the 302 and fetched the playlist once.
      assert_receive {:bandit_playlist, 4_209}, 1_000
      assert_receive {:bandit_playlist, 4_209}, 1_000

      # Serving the live playlist prefetches the segment at live edge minus
      # liveSyncDurationCount=3 (index 5 - 3 = 2 -> seg-4211.ts).
      assert_receive {:bandit_segment, "/hls/501/seg-4211.ts"}, 1_000
      wait_for_prefetch_idle(sid)
      refute_received {:bandit_segment, "/hls/501/seg-4209.ts"}
      refute_received {:bandit_segment, "/hls/501/seg-4210.ts"}

      # Even if the upstream sequence advances before the immediate variant
      # request arrives (< 2 s), the variant reuses the master's playlist
      # without hitting upstream again.
      Agent.update(context.sequence, &(&1 + 1))
      variant = get(build_conn(), live)
      assert variant.status == 200
      assert variant.resp_body =~ "#EXT-X-MEDIA-SEQUENCE:4209"
      refute_received {:bandit_playlist, _seq}

      segments = lines(variant.resp_body)
      assert length(segments) == 5

      # The player requests the live-sync segment (index 2, seg-4211.ts): it is
      # served straight from SegmentCache (no second fetch of seg-4211.ts) and
      # advances lookahead to seg-4212.ts.
      first_segment = get(build_conn(), Enum.at(segments, 2))
      assert first_segment.status == 200
      assert first_segment.resp_body == @ts_segment
      refute_received {:bandit_segment, "/hls/501/seg-4211.ts"}

      assert_receive {:bandit_segment, "/hls/501/seg-4212.ts"}, 1_000
      wait_for_prefetch_idle(sid)

      # The next playlist refresh goes upstream and gets the new sequence.
      refresh = get(build_conn(), live)
      assert refresh.status == 200
      assert refresh.resp_body =~ "#EXT-X-MEDIA-SEQUENCE:4210"
      assert_receive {:bandit_playlist, 4_210}, 1_000
    end

    test "refetches the variant playlist upstream when the master playlist TTL expires",
         context do
      master = get(build_conn(), context.master)
      [live] = lines(master.resp_body)
      sid = session_id(live)

      assert_receive {:bandit_playlist, 4_209}, 1_000
      assert_receive {:bandit_playlist, 4_209}, 1_000
      assert_receive {:bandit_segment, "/hls/501/seg-4211.ts"}, 1_000
      wait_for_prefetch_idle(sid)

      # Age the stashed master playlist past its 2 s TTL.
      expired_at = System.monotonic_time(:millisecond) - 1

      :sys.replace_state(Sessions, fn state ->
        update_in(state.sessions[sid].live_playlists, fn live_playlists ->
          Map.new(live_playlists, fn {rid, {template, _}} -> {rid, {template, expired_at}} end)
        end)
      end)

      Agent.update(context.sequence, &(&1 + 3))

      variant = get(build_conn(), live)
      assert variant.status == 200
      assert variant.resp_body =~ "#EXT-X-MEDIA-SEQUENCE:4212"
      assert_receive {:bandit_playlist, 4_212}, 1_000

      # The fresh playlist's live-sync segment (4212 + 2 = 4214) is prefetched.
      assert_receive {:bandit_segment, "/hls/501/seg-4214.ts"}, 1_000
      wait_for_prefetch_idle(sid)
    end
  end

  defp master_path(token), do: "/api/stream/hls/master.m3u8?token=#{encoded(token)}"
  defp encoded(token), do: URI.encode_www_form(token)

  defp swap_token(path, old, new), do: String.replace(path, encoded(old), encoded(new))

  defp aged_token(channel_id, seconds) do
    Phoenix.Token.encrypt(
      Endpoint,
      "stream",
      %{type: "channel", id: channel_id, user_id: nil, bypass: true},
      signed_at: System.system_time(:second) - seconds
    )
  end

  defp lines(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  defp session_id(path),
    do: path |> URI.parse() |> Map.fetch!(:path) |> Path.split() |> Enum.at(4)

  defp refute_leak(response) do
    exposed = [response.resp_body | Enum.map(response.resp_headers, &elem(&1, 1))]

    for value <- exposed, secret <- [@user, @pass, @panel, @cdn, "cdn-token"] do
      refute value =~ secret, "#{inspect(secret)} leaked into #{inspect(value)}"
    end
  end

  # Counts (and drains) upstream requests to the panel's live URLs.
  defp probes(count \\ 0) do
    receive do
      {:upstream, "/live/" <> _} -> probes(count + 1)
      {:upstream, _other} -> probes(count)
    after
      0 -> count
    end
  end

  defp playlist_fetches(count \\ 0) do
    receive do
      {:upstream, "/hls/" <> rest} ->
        playlist_fetches(if String.ends_with?(rest, ".m3u8"), do: count + 1, else: count)

      {:upstream, _other} ->
        playlist_fetches(count)
    after
      0 -> count
    end
  end

  defp wait_for_waiters(count) do
    pending = :sys.get_state(SegmentCache).pending

    if Enum.any?(pending, fn {_key, %{waiters: waiters}} -> length(waiters) >= count end),
      do: :ok,
      else: wait_for_waiters(count)
  end

  defp wait_for_prefetch_idle(session_id) do
    if MapSet.size(:sys.get_state(Sessions).sessions[session_id].prefetching) > 0,
      do: wait_for_prefetch_idle(session_id),
      else: :ok
  end

  defp start_bandit_upstream(owner, sequence) do
    {:ok, server} =
      start_supervised(
        {Bandit,
         plug: {__MODULE__.LiveBanditPlug, owner: owner, sequence: sequence},
         port: 0,
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    {:ok, port}
  end

  defmodule BanditAdapter do
    @moduledoc false

    def run(request) do
      port = :persistent_term.get({StreamixWeb.XtreamLiveHlsTest, :bandit_port})

      Req.Finch.run(%{
        request
        | url: %{request.url | scheme: "http", host: "127.0.0.1", port: port}
      })
    end
  end

  defmodule LiveBanditPlug do
    @moduledoc false

    import Plug.Conn

    @cdn "104.16.3.3"
    @ts_segment <<0x47>> <> :binary.copy(<<0>>, 187) <> <<0x47>> <> :binary.copy(<<1>>, 187)

    def init(opts), do: opts

    def call(%{request_path: "/live/megauser/s3cr3t-Pa55word/" <> file} = conn, _opts) do
      channel = Path.rootname(file)

      conn
      |> put_resp_header(
        "location",
        "https://#{@cdn}/hls/#{channel}/index.m3u8?token=cdn-token"
      )
      |> send_resp(302, "")
    end

    def call(%{request_path: "/hls/" <> rest} = conn, opts) do
      owner = Keyword.fetch!(opts, :owner)
      sequence = Keyword.fetch!(opts, :sequence)

      case Path.split(rest) do
        [_channel, "index.m3u8"] ->
          seq = Agent.get(sequence, & &1)
          send(owner, {:bandit_playlist, seq})

          segments = for n <- seq..(seq + 4), do: "#EXTINF:10.0,\nseg-#{n}.ts\n"

          body =
            IO.iodata_to_binary([
              "#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-TARGETDURATION:10\n",
              "#EXT-X-MEDIA-SEQUENCE:#{seq}\n",
              segments
            ])

          conn
          |> put_resp_content_type("application/vnd.apple.mpegurl", nil)
          |> send_resp(200, body)

        [_channel, "seg-" <> _] ->
          send(owner, {:bandit_segment, conn.request_path})

          conn
          |> put_resp_content_type("video/mp2t", nil)
          |> send_resp(200, @ts_segment)
      end
    end
  end

  # Channel 501: live HLS on the CDN. 123: redirects to a third-party embed
  # page. 81: its playlist exists but its segments are gone. 900: plain TS.
  defp upstream(%{host: @panel, request_path: "/live/megauser/s3cr3t-Pa55word/123.ts"} = conn, _),
    do: redirect_to(conn, "https://104.16.9.9/canal/some-channel")

  defp upstream(%{host: @panel, request_path: "/live/megauser/s3cr3t-Pa55word/900.ts"} = conn, _) do
    conn
    |> put_resp_content_type("video/mp2t", nil)
    |> send_resp(200, @ts_segment)
  end

  defp upstream(
         %{host: @panel, request_path: "/live/megauser/s3cr3t-Pa55word/" <> file} = conn,
         _
       ),
       do:
         redirect_to(
           conn,
           "https://#{@cdn}/hls/#{Path.rootname(file)}/index.m3u8?token=cdn-token"
         )

  defp upstream(%{host: "104.16.9.9"} = conn, _) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, "<!DOCTYPE html><html><body>embed</body></html>")
  end

  defp upstream(%{request_path: "/hls/" <> rest} = conn, sequence) do
    case Path.split(rest) do
      [_channel, "index.m3u8"] ->
        conn
        |> put_resp_content_type("application/vnd.apple.mpegurl", nil)
        |> send_resp(200, live_playlist(Agent.get(sequence, & &1)))

      ["81", "seg-" <> _] ->
        send_resp(conn, 404, "gone")

      [_channel, "seg-" <> _] ->
        conn
        |> put_resp_content_type("video/mp2t", nil)
        |> send_resp(200, @ts_segment)
    end
  end

  defp redirect_to(conn, location) do
    conn
    |> put_resp_header("location", location)
    |> send_resp(302, "")
  end

  defp live_playlist(sequence) do
    segments = for n <- sequence..(sequence + 4), do: "#EXTINF:10.0,\nseg-#{n}.ts\n"

    IO.iodata_to_binary([
      "#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-TARGETDURATION:10\n",
      "#EXT-X-MEDIA-SEQUENCE:#{sequence}\n",
      segments
    ])
  end
end
