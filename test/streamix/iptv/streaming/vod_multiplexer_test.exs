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

  describe "parse_range_start/1" do
    test "reads open-ended and closed ranges" do
      assert VodMultiplexer.parse_range_start("bytes=1500-") == 1_500
      assert VodMultiplexer.parse_range_start("bytes=0-1023") == 0
    end

    test "falls back to the start of the file" do
      assert VodMultiplexer.parse_range_start(nil) == 0
      assert VodMultiplexer.parse_range_start("garbage") == 0
      assert VodMultiplexer.parse_range_start("bytes=-500") == 0
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

      # One connection is all the provider allows. Without block sharing this
      # is exactly the situation that answers everyone but the first with 503.
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

  defp expected_body do
    for index <- 0..(@body_size - 1), into: <<>>, do: <<rem(index, 256)>>
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
      :counters.add(Keyword.fetch!(opts, :counter), 1, 1)

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
