defmodule Streamix.Iptv.Streaming.VodMultiplexerTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Streamix.Iptv.ProviderCapabilities
  alias Streamix.Iptv.Streaming.ProviderRuntime
  alias Streamix.Iptv.Streaming.VodMultiplexer
  alias Streamix.Iptv.Streaming.VodMultiplexer.BlockStore

  @block_size 1_024
  @body_size 4_096

  setup do
    cache_dir =
      Path.join(System.tmp_dir!(), "streamix-vod-test-#{System.unique_integer([:positive])}")

    previous_block_size = Application.get_env(:streamix, :vod_block_size_bytes)
    previous_cache_dir = Application.get_env(:streamix, :vod_cache_dir)

    Application.put_env(:streamix, :vod_block_size_bytes, @block_size)
    Application.put_env(:streamix, :vod_cache_dir, cache_dir)

    BlockStore.reset()
    ProviderRuntime.reset()

    on_exit(fn ->
      BlockStore.reset()
      ProviderRuntime.reset()
      File.rm_rf(cache_dir)

      restore(:vod_block_size_bytes, previous_block_size)
      restore(:vod_cache_dir, previous_cache_dir)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:streamix, key)
  defp restore(key, value), do: Application.put_env(:streamix, key, value)

  describe "block math" do
    test "maps an aligned range onto whole blocks" do
      assert VodMultiplexer.blocks_for(0, 2047, 1_024) == [{0, 0, 1_024}, {1, 0, 1_024}]
    end

    test "keeps the offset of a range starting mid-block" do
      assert VodMultiplexer.blocks_for(1_500, 2_047, 1_024) == [{1, 476, 548}]
    end

    test "clamps the final block to the requested end" do
      assert [{0, 0, 1_024}, {1, 0, 100}] = VodMultiplexer.blocks_for(0, 1_123, 1_024)
    end

    test "returns nothing for an inverted range" do
      assert VodMultiplexer.blocks_for(100, 50, 1_024) == []
    end
  end

  describe "parse_range/1" do
    test "reads open-ended and closed ranges" do
      assert VodMultiplexer.parse_range("bytes=1500-") == {1_500, :eof}
      assert VodMultiplexer.parse_range("bytes=0-1023") == {0, 1_023}
    end

    test "falls back to the whole resource" do
      assert VodMultiplexer.parse_range(nil) == {0, :eof}
      assert VodMultiplexer.parse_range("garbage") == {0, :eof}
      assert VodMultiplexer.parse_range("bytes=-500") == {0, :eof}
    end

    test "parse_range_start/1 still reports where playback resumes" do
      assert VodMultiplexer.parse_range_start("bytes=1500-") == 1_500
      assert VodMultiplexer.parse_range_start("bytes=0-1023") == 0
    end
  end

  describe "content_key/1" do
    test "is stable for the same content regardless of the signed URL" do
      first = VodMultiplexer.content_key(provider_id: 3, content_id: 42, url: "http://a/one")
      second = VodMultiplexer.content_key(provider_id: 3, content_id: 42, url: "http://b/two")

      assert first == second
    end

    test "separates content types and providers" do
      movie = VodMultiplexer.content_key(provider_id: 3, content_id: 42, media_type: "movie")
      episode = VodMultiplexer.content_key(provider_id: 3, content_id: 42, media_type: "episode")
      other = VodMultiplexer.content_key(provider_id: 4, content_id: 42, media_type: "movie")

      assert movie != episode
      assert movie != other
    end

    test "falls back to the URL when there is no content context" do
      assert "url:" <> _ = VodMultiplexer.content_key(url: "http://example.test/movie.mp4")
    end
  end

  describe "a provider that stops sending bytes" do
    setup do
      previous = Application.get_env(:streamix, :vod_block_deadline_ms)
      Application.put_env(:streamix, :vod_block_deadline_ms, 300)

      on_exit(fn ->
        if previous do
          Application.put_env(:streamix, :vod_block_deadline_ms, previous)
        else
          Application.delete_env(:streamix, :vod_block_deadline_ms)
        end
      end)

      :ok
    end

    test "gives the provider slot back instead of holding it forever" do
      {:ok, port} = start_stalling_stub()
      url = "http://127.0.0.1:#{port}/stalled.mp4"
      provider_id = 9_100

      ProviderRuntime.put_capabilities(
        provider_id,
        struct!(ProviderCapabilities,
          authenticated?: true,
          active?: true,
          max_connections: 1
        )
      )

      conn = pipe(conn(:get, "/proxy"), url, provider_id: provider_id, content_id: 1)

      # Whatever the viewer ends up being told, the slot must not stay leased:
      # with max_connections at 1, a stranded lease locks every later viewer
      # out of the provider entirely — including this viewer's own retry.
      assert conn.state in [:sent, :chunked, :file]
      assert %{capacity: %{leased_connections: 0}} = ProviderRuntime.snapshot(provider_id)
    end
  end

  describe "remembering the resource length across restarts" do
    test "recovers a persisted total size after the in-memory index is gone" do
      content_key = "url:http://example.test/restart.mp4"

      BlockStore.put_total_size(content_key, 2_963_452_723)
      assert BlockStore.total_size(content_key) == 2_963_452_723

      # A deploy restarts the app: ETS starts empty while the cache volume
      # survives. Losing the length here is what makes an already-cached
      # movie stop playing, because the multiplexer can no longer answer a
      # 206 and falls back to the length-less direct proxy.
      :ets.delete_all_objects(BlockStore.Meta)

      assert BlockStore.total_size(content_key) == 2_963_452_723
    end

    test "reports no length for content it never saw" do
      assert BlockStore.total_size("url:http://example.test/never-seen.mp4") == nil
    end

    test "reset clears the persisted length too" do
      content_key = "url:http://example.test/wiped.mp4"
      BlockStore.put_total_size(content_key, 1_234)

      BlockStore.reset()

      assert BlockStore.total_size(content_key) == nil
    end
  end

  describe "serving through the block cache" do
    setup do
      counter = :counters.new(1, [:atomics])
      {:ok, port} = start_stub(counter)

      %{counter: counter, url: "http://127.0.0.1:#{port}/movie.mp4"}
    end

    test "serves a full stream and reports the real length", %{url: url, counter: counter} do
      conn = pipe(conn(:get, "/proxy"), url, provider_id: 7_001, content_id: 1)

      assert conn.status == 206
      assert byte_size(conn.resp_body) == @body_size
      assert conn.resp_body == expected_body()

      assert Plug.Conn.get_resp_header(conn, "content-range") == [
               "bytes 0-#{@body_size - 1}/#{@body_size}"
             ]

      assert :counters.get(counter, 1) == div(@body_size, @block_size)
    end

    test "honours a mid-block Range", %{url: url} do
      conn =
        conn(:get, "/proxy")
        |> Plug.Conn.put_req_header("range", "bytes=1500-")
        |> pipe(url, provider_id: 7_002, content_id: 2)

      assert conn.status == 206
      assert conn.resp_body == binary_slice(expected_body(), 1_500, @body_size - 1_500)

      assert Plug.Conn.get_resp_header(conn, "content-range") == [
               "bytes 1500-#{@body_size - 1}/#{@body_size}"
             ]
    end

    test "answers a closed Range with exactly the bytes requested", %{url: url} do
      # Players probe with a bounded range. Promising the whole file in
      # Content-Range when 1 KiB was asked for breaks the HTTP contract, and
      # the player reacts by dropping the response — a black screen.
      conn =
        conn(:get, "/proxy")
        |> Plug.Conn.put_req_header("range", "bytes=0-1023")
        |> pipe(url, provider_id: 7_010, content_id: 10)

      assert conn.status == 206
      assert byte_size(conn.resp_body) == 1_024
      assert conn.resp_body == binary_slice(expected_body(), 0, 1_024)
      assert Plug.Conn.get_resp_header(conn, "content-range") == ["bytes 0-1023/#{@body_size}"]
    end

    test "answers a closed Range that spans several blocks", %{url: url} do
      conn =
        conn(:get, "/proxy")
        |> Plug.Conn.put_req_header("range", "bytes=1500-3000")
        |> pipe(url, provider_id: 7_011, content_id: 11)

      assert conn.status == 206
      assert byte_size(conn.resp_body) == 1_501
      assert conn.resp_body == binary_slice(expected_body(), 1_500, 1_501)
      assert Plug.Conn.get_resp_header(conn, "content-range") == ["bytes 1500-3000/#{@body_size}"]
    end

    test "clamps a Range that runs past the end of the resource", %{url: url} do
      conn =
        conn(:get, "/proxy")
        |> Plug.Conn.put_req_header("range", "bytes=0-999999")
        |> pipe(url, provider_id: 7_012, content_id: 12)

      assert conn.status == 206
      assert byte_size(conn.resp_body) == @body_size

      assert Plug.Conn.get_resp_header(conn, "content-range") == [
               "bytes 0-#{@body_size - 1}/#{@body_size}"
             ]
    end

    test "warms the following block while the current one is being written", %{url: url} do
      opts = [provider_id: 7_013, content_id: 13]
      key = VodMultiplexer.content_key(opts ++ [url: url])

      # Only the first block is asked for, so without readahead nothing else
      # would ever be fetched.
      conn(:get, "/proxy")
      |> Plug.Conn.put_req_header("range", "bytes=0-1023")
      |> pipe(url, opts)

      assert warmed?(key, 1), "expected block 1 to have been prefetched"
    end

    test "does not warm past the end of the resource", %{url: url} do
      opts = [provider_id: 7_014, content_id: 14]
      key = VodMultiplexer.content_key(opts ++ [url: url])

      pipe(conn(:get, "/proxy"), url, opts)

      # The resource is four blocks long, so there is no block 4 to warm.
      refute warmed?(key, 4)
    end

    test "a second viewer is served entirely from cache", %{url: url, counter: counter} do
      opts = [provider_id: 7_003, content_id: 3]

      first = pipe(conn(:get, "/proxy"), url, opts)
      upstream_after_first = :counters.get(counter, 1)

      second = pipe(conn(:get, "/proxy"), url, opts)

      assert first.resp_body == second.resp_body
      assert :counters.get(counter, 1) == upstream_after_first
    end

    test "concurrent viewers of one movie collapse onto a single upstream fetch per block",
         %{url: url, counter: counter} do
      opts = [provider_id: 7_004, content_id: 4]

      # One upstream connection is all that is allowed. Without block sharing
      # this is exactly the situation that answers everyone but the first
      # viewer with a 503.
      previous_ceiling = Application.get_env(:streamix, :vod_connection_ceiling)
      Application.put_env(:streamix, :vod_connection_ceiling, 1)
      on_exit(fn -> restore(:vod_connection_ceiling, previous_ceiling) end)

      ProviderRuntime.put_capabilities(7_004, %ProviderCapabilities{
        authenticated?: true,
        active?: true,
        max_connections: 1
      })

      responses =
        1..8
        |> Task.async_stream(fn _ -> pipe(conn(:get, "/proxy"), url, opts) end,
          max_concurrency: 8,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, conn} -> conn end)

      assert Enum.all?(responses, &(&1.status == 206))
      assert Enum.all?(responses, &(&1.resp_body == expected_body()))

      # Eight viewers, but the upstream only ever saw one request per block.
      assert :counters.get(counter, 1) == div(@body_size, @block_size)
    end

    test "falls back to the direct proxy when the provider has no free slot", %{url: url} do
      provider_id = 7_005

      # VOD capacity is governed by :vod_connection_ceiling, not by the limit
      # the provider reports, so exhausting it means pinning the ceiling.
      previous_ceiling = Application.get_env(:streamix, :vod_connection_ceiling)
      Application.put_env(:streamix, :vod_connection_ceiling, 1)
      on_exit(fn -> restore(:vod_connection_ceiling, previous_ceiling) end)

      ProviderRuntime.put_capabilities(provider_id, %ProviderCapabilities{
        authenticated?: true,
        active?: true,
        max_connections: 1
      })

      {:ok, held} = ProviderRuntime.acquire(provider_id, :vod)

      conn =
        VodMultiplexer.pipe(
          conn(:get, "/proxy"),
          url,
          [provider_id: provider_id, content_id: 5],
          fn conn -> Plug.Conn.send_resp(conn, 555, "fallback") end
        )

      assert conn.status == 555
      assert conn.resp_body == "fallback"

      ProviderRuntime.release(held)
    end
  end

  defp pipe(conn, url, opts) do
    VodMultiplexer.pipe(conn, url, opts, fn conn ->
      Plug.Conn.send_resp(conn, 555, "fallback")
    end)
  end

  # Readahead is dispatched synchronously while the current block is written,
  # so by the time `pipe/3` returns the fetcher either exists or has already
  # stored the block. No waiting required.
  defp warmed?(key, index) do
    fetching? = Registry.lookup(Streamix.StreamRegistry, {:vod_block, key, index}) != []

    fetching? or BlockStore.lookup({key, index}) != :miss
  end

  defp expected_body do
    for index <- 0..(@body_size - 1), into: <<>>, do: <<rem(index, 256)>>
  end

  defp start_stalling_stub do
    {:ok, server} =
      start_supervised({Bandit, plug: __MODULE__.StallingPlug, port: 0, startup_log: false},
        id: :stalling_stub
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    {:ok, port}
  end

  defmodule StallingPlug do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    # Answers the headers so the connection looks healthy, then never sends
    # the body — the shape of a provider that accepts the request and then
    # trickles nothing. Finch's per-receive timeout never fires because the
    # socket stays open.
    def call(conn, _opts) do
      conn =
        conn
        |> put_resp_header("content-range", "bytes 0-4095/4096")
        |> put_resp_header("content-type", "video/mp4")
        |> send_chunked(206)

      # Hold the response open until the test lets go. The `after` clause is
      # only a safety net so a failing test cannot wedge the suite.
      receive do
        :release_stalled_request -> conn
      after
        2_000 -> conn
      end
    end
  end

  defp start_stub(counter) do
    {:ok, server} =
      start_supervised(
        {Bandit, plug: {__MODULE__.RangePlug, counter: counter}, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    {:ok, port}
  end

  defmodule RangePlug do
    @moduledoc false

    import Plug.Conn

    @body_size 4_096

    def init(opts), do: opts

    def call(conn, opts) do
      # Only range requests are counted: those are the block fetches the
      # multiplexer is meant to share. The redirect resolver also hits this
      # plug once per URL to walk the chain, which is not per-viewer work.
      if get_req_header(conn, "range") != [] do
        :counters.add(Keyword.fetch!(opts, :counter), 1, 1)
      end

      body = for index <- 0..(@body_size - 1), into: <<>>, do: <<rem(index, 256)>>

      case range(conn) do
        {:ok, range_start, range_end} when range_start < @body_size ->
          range_end = min(range_end, @body_size - 1)
          slice = binary_slice(body, range_start, range_end - range_start + 1)

          conn
          |> put_resp_header(
            "content-range",
            "bytes #{range_start}-#{range_end}/#{@body_size}"
          )
          |> put_resp_header("content-type", "video/mp4")
          |> send_resp(206, slice)

        {:ok, _range_start, _range_end} ->
          send_resp(conn, 416, "")

        :none ->
          send_resp(conn, 200, body)
      end
    end

    defp range(conn) do
      case get_req_header(conn, "range") do
        ["bytes=" <> spec | _] ->
          case String.split(spec, "-", parts: 2) do
            [range_start, ""] ->
              {:ok, String.to_integer(range_start), @body_size - 1}

            [range_start, range_end] ->
              {:ok, String.to_integer(range_start), String.to_integer(range_end)}

            _ ->
              :none
          end

        _ ->
          :none
      end
    end
  end
end
