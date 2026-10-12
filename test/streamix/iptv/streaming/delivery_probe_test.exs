defmodule Streamix.Iptv.Streaming.DeliveryProbeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Streamix.Iptv.Streaming.DeliveryProbe

  @user "megauser"
  @pass "s3cr3t-Pa55word"
  @panel "93.184.216.34"
  @redirector "104.16.1.1"
  @cdn "104.16.2.2"
  @final "https://#{@cdn}/movies/7/7.mp4?username=#{@user}&token=tkn-123"

  setup do
    original = Application.get_env(:streamix, :xtream_delivery, [])
    Application.put_env(:streamix, :xtream_delivery, http_options: [plug: {Req.Test, __MODULE__}])
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Application.put_env(:streamix, :xtream_delivery, original) end)

    provider = %{
      id: System.unique_integer([:positive]),
      url: "http://#{@panel}",
      username: @user,
      password: @pass
    }

    movie = %{id: 1, stream_id: 100_664, container_extension: "mp4", source_ids: nil}
    %{provider: provider, movie: movie}
  end

  defp record(fun) do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:hop, conn.method, conn.host, conn.request_path, conn.query_string})
      fun.(conn)
    end)
  end

  defp redirect(conn, location) do
    conn
    |> Plug.Conn.put_resp_header("location", location)
    |> Plug.Conn.send_resp(302, "")
  end

  # The measured chain: panel → redirector → progressive CDN that refuses
  # this server with a Cloudflare page.
  defp blocked_chain(%{host: @panel} = conn), do: redirect(conn, "https://#{@redirector}/r/abc")

  defp blocked_chain(%{host: @redirector} = conn),
    do: redirect(conn, "http://#{@cdn}:80/movies/7/7.mp4?username=#{@user}&token=tkn-123")

  defp blocked_chain(%{host: @cdn} = conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(403, "<title>Attention Required! | Cloudflare</title>")
  end

  defp hls(conn, type \\ "application/vnd.apple.mpegurl") do
    conn
    |> Plug.Conn.put_resp_content_type(type, nil)
    |> Plug.Conn.send_resp(200, "#EXTM3U\n#EXT-X-VERSION:6\n")
  end

  test "a progressive CDN that refuses this server is handed to the client over https",
       context do
    record(&blocked_chain/1)

    assert {:ok, {:direct, @final, "mp4"}} =
             DeliveryProbe.decide(context.provider, :movie, context.movie)

    # Every hop is a GET (one redirector answers HEAD with 200), in order.
    assert_received {:hop, "GET", @panel, "/movie/megauser/s3cr3t-Pa55word/100664.mp4",
                     "source=1"}

    assert_received {:hop, "GET", @redirector, "/r/abc", ""}
    assert_received {:hop, "GET", @cdn, "/movies/7/7.mp4", _query}
    refute_received {:hop, _method, _host, _path, _query}
  end

  test "an HLS source is served through the gateway, recognised by type or body", context do
    record(fn
      %{host: @panel} = conn -> redirect(conn, "https://#{@redirector}/hls/master")
      conn -> hls(conn)
    end)

    assert {:ok, {:hls, root}} = DeliveryProbe.decide(context.provider, :movie, context.movie)
    assert root == "http://#{@panel}/movie/#{@user}/#{@pass}/100664.mp4?source=1"

    provider = %{context.provider | id: System.unique_integer([:positive])}

    record(fn
      %{host: @panel} = conn -> redirect(conn, "https://#{@redirector}/hls/master")
      conn -> hls(conn, "text/plain")
    end)

    assert {:ok, {:hls, _root}} = DeliveryProbe.decide(provider, :movie, context.movie)
  end

  test "sources are tried in the provider's order, skipping dead ones", context do
    movie = %{context.movie | source_ids: [4, 2]}

    record(fn
      %{query_string: "source=4"} = conn ->
        Plug.Conn.send_resp(conn, 404, "No playable stream found.")

      %{host: @panel} = conn ->
        redirect(conn, "https://#{@redirector}/hls/master")

      conn ->
        hls(conn)
    end)

    assert {:ok, {:hls, root}} = DeliveryProbe.decide(context.provider, :movie, movie)
    assert String.ends_with?(root, "?source=2")

    assert_received {:hop, "GET", @panel, _path, "source=4"}
    assert_received {:hop, "GET", @panel, _path, "source=2"}
    refute_received {:hop, "GET", @panel, _path, "source=1"}
  end

  test "episodes are probed on the series path", context do
    record(fn
      %{host: @panel} = conn -> redirect(conn, "https://#{@redirector}/hls/master")
      conn -> hls(conn)
    end)

    episode = %{id: 9, episode_id: 555, container_extension: "mp4", source_ids: [1]}
    assert {:ok, {:hls, root}} = DeliveryProbe.decide(context.provider, :episode, episode)
    assert root == "http://#{@panel}/series/#{@user}/#{@pass}/555.mp4?source=1"
  end

  describe "refusals" do
    test "a final URL that still carries the password is never handed out", context do
      record(fn
        %{host: @panel} = conn -> redirect(conn, "https://#{@cdn}/v/#{@pass}/7.mp4")
        conn -> Plug.Conn.send_resp(conn, 403, "blocked")
      end)

      assert {:error, :upstream_unavailable} =
               DeliveryProbe.decide(context.provider, :movie, context.movie)
    end

    test "the panel's own URL is never handed out, whatever it answers", context do
      record(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("video/mp4", nil)
        |> Plug.Conn.send_resp(200, "ftyp")
      end)

      assert {:error, :upstream_unavailable} =
               DeliveryProbe.decide(context.provider, :movie, context.movie)
    end

    test "every hop is SSRF-checked before it is requested", context do
      record(fn conn -> redirect(conn, "http://127.0.0.1/internal.mp4") end)

      assert {:error, :upstream_unavailable} =
               DeliveryProbe.decide(context.provider, :movie, context.movie)

      refute_received {:hop, _method, "127.0.0.1", _path, _query}
    end

    test "a redirect loop stops at the hop limit", context do
      record(fn conn -> redirect(conn, "https://#{@redirector}/loop") end)
      movie = %{context.movie | source_ids: [1]}

      assert {:error, :upstream_unavailable} =
               DeliveryProbe.decide(context.provider, :movie, movie)

      # One request to the panel, then at most five redirects.
      assert hops() == 6
    end

    test "an item whose every source is gone is a clear not-found", context do
      record(&Plug.Conn.send_resp(&1, 404, "No playable stream found."))

      assert {:error, :upstream_not_found} =
               DeliveryProbe.decide(context.provider, :movie, context.movie)
    end
  end

  describe "cache" do
    test "a decision is reused, and concurrent first requests share one probe", context do
      record(&blocked_chain/1)

      tasks =
        for _ <- 1..5,
            do:
              Task.async(fn -> DeliveryProbe.decide(context.provider, :movie, context.movie) end)

      results = Task.await_many(tasks)

      assert Enum.uniq(results) == [{:ok, {:direct, @final, "mp4"}}]
      assert DeliveryProbe.decide(context.provider, :movie, context.movie) == hd(results)
      assert hops() == 3
    end

    test "a decision past its TTL is probed again", context do
      Application.put_env(:streamix, :xtream_delivery,
        http_options: [plug: {Req.Test, __MODULE__}],
        direct_ttl_seconds: 0
      )

      record(&blocked_chain/1)

      assert {:ok, {:direct, _url, _ext}} =
               DeliveryProbe.decide(context.provider, :movie, context.movie)

      assert {:ok, {:direct, _url, _ext}} =
               DeliveryProbe.decide(context.provider, :movie, context.movie)

      assert hops() == 6
    end

    test "changed credentials never reuse a decision", context do
      record(&blocked_chain/1)
      assert {:ok, _} = DeliveryProbe.decide(context.provider, :movie, context.movie)
      assert DeliveryProbe.peek(context.provider, :movie, context.movie) != :miss

      rotated = %{context.provider | password: "rotated-secret"}
      assert DeliveryProbe.peek(rotated, :movie, context.movie) == :miss
    end
  end

  test "no log line carries the password, the username or the CDN token", context do
    log =
      capture_log([level: :debug], fn ->
        record(&blocked_chain/1)
        DeliveryProbe.decide(context.provider, :movie, context.movie)

        record(&Plug.Conn.send_resp(&1, 404, "No playable stream found."))
        DeliveryProbe.decide(%{context.provider | id: -1}, :movie, context.movie)
      end)

    for secret <- [@pass, @user, "tkn-123", @cdn] do
      refute log =~ secret
    end
  end

  defp hops(count \\ 0) do
    receive do
      {:hop, _method, _host, _path, _query} -> hops(count + 1)
    after
      0 -> count
    end
  end
end
