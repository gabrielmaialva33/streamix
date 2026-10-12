defmodule Streamix.Hls.SegmentCacheTest do
  use ExUnit.Case, async: false

  alias Streamix.Hls.SegmentCache

  @ts <<0x47>> <> :binary.copy(<<0>>, 187)

  setup do
    original = Application.get_env(:streamix, :hls_segment_cache, [])
    on_exit(fn -> Application.put_env(:streamix, :hls_segment_cache, original) end)
    :ok = SegmentCache.flush()
    %{key: "https://93.184.216.34/live/seg-#{System.unique_integer([:positive])}.ts"}
  end

  defp media(body \\ @ts),
    do: {:ok, %{status: 200, body: body, headers: %{"content-type" => ["video/mp2t"]}}}

  test "concurrent viewers of one segment share a single upstream fetch", %{key: key} do
    owner = self()

    fetch = fn ->
      send(owner, {:upstream, self()})

      receive do
        :release -> media()
      end
    end

    viewers = for _ <- 1..4, do: Task.async(fn -> SegmentCache.fetch(key, fetch) end)

    assert_receive {:upstream, upstream}
    wait_for_waiters(key, 4)
    send(upstream, :release)

    assert Enum.uniq(Task.await_many(viewers)) == [media()]
    refute_received {:upstream, _pid}

    # A later viewer is served from the cache.
    assert SegmentCache.fetch(key, fn -> flunk("refetched a cached segment") end) == media()
    assert SegmentCache.bytes() == byte_size(@ts)
  end

  test "a segment past its TTL is fetched again", %{key: key} do
    Application.put_env(:streamix, :hls_segment_cache, ttl_ms: 1)
    owner = self()

    fetch = fn ->
      send(owner, :upstream)
      media()
    end

    assert SegmentCache.fetch(key, fetch) == media()
    stored_at = System.monotonic_time(:millisecond)
    wait_until(stored_at + 2)

    assert SegmentCache.fetch(key, fetch) == media()
    assert_received :upstream
    assert_received :upstream
  end

  test "errors, playlists, empty and oversized bodies are never kept", %{key: key} do
    Application.put_env(:streamix, :hls_segment_cache, max_entry_bytes: 300)
    owner = self()

    for result <- [
          {:error, :upstream_not_found},
          {:ok,
           %{
             status: 200,
             body: "#EXTM3U\n",
             headers: %{"content-type" => ["application/vnd.apple.mpegurl"]}
           }},
          {:ok, %{status: 206, body: @ts, headers: %{"content-type" => ["video/mp2t"]}}},
          media(""),
          media(:binary.copy(@ts, 2))
        ] do
      fetch = fn ->
        send(owner, :upstream)
        result
      end

      assert SegmentCache.fetch(key, fetch) == result
      assert SegmentCache.fetch(key, fetch) == result
      assert_received :upstream
      assert_received :upstream
    end

    assert SegmentCache.bytes() == 0
  end

  test "memory stays under its bound by dropping the oldest segments first" do
    Application.put_env(:streamix, :hls_segment_cache, max_bytes: 3 * 188)
    keys = for n <- 1..5, do: "https://93.184.216.34/live/bound-#{n}.ts"

    for key <- keys, do: assert(SegmentCache.fetch(key, fn -> media() end) == media())

    assert SegmentCache.bytes() == 3 * 188

    # The two oldest were dropped; the three newest are still served cached.
    for key <- Enum.take(keys, -3) do
      assert SegmentCache.fetch(key, fn -> flunk("evicted too early") end) == media()
    end

    owner = self()

    SegmentCache.fetch(hd(keys), fn ->
      send(owner, :refetched)
      media()
    end)

    assert_received :refetched
  end

  defp wait_for_waiters(key, count) do
    case :sys.get_state(SegmentCache).pending[key] do
      %{waiters: waiters} when length(waiters) >= count -> :ok
      _ -> wait_for_waiters(key, count)
    end
  end

  # Spins until the monotonic clock passes `deadline` (a few milliseconds).
  defp wait_until(deadline) do
    if System.monotonic_time(:millisecond) <= deadline, do: wait_until(deadline), else: :ok
  end
end
