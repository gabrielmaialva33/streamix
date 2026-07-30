defmodule Streamix.Iptv.Streaming.RedirectResolverTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Streamix.Iptv.Streaming.RedirectResolver

  setup do
    RedirectResolver.clear_cache()
    counter = start_supervised!({Agent, fn -> %{} end})
    port = start_test_server(counter, self())
    base = "http://127.0.0.1:#{port}"
    %{base: base, counter: counter}
  end

  describe "resolve/2" do
    test "follows the redirect chain and returns the final URL", %{base: base, counter: counter} do
      assert {:ok, final} = RedirectResolver.resolve("#{base}/r1")
      assert final == "#{base}/final"
      assert Agent.get(counter, & &1) == %{"/r1" => 1, "/r2" => 1, "/final" => 1}
    end

    test "second call hits the cache", %{base: base, counter: counter} do
      {:ok, _} = RedirectResolver.resolve("#{base}/r1")
      hits_after_first = Agent.get(counter, & &1)

      {:ok, _} = RedirectResolver.resolve("#{base}/r1")
      assert Agent.get(counter, & &1) == hits_after_first
    end

    test "concurrent callers single-flight a single resolution", %{base: base, counter: counter} do
      slow = "#{base}/slow"

      tasks =
        for _ <- 1..8 do
          Task.async(fn -> RedirectResolver.resolve(slow) end)
        end

      assert_receive {:request_started, "/slow", request_pid}
      send(request_pid, :release_slow_request)

      results = Task.await_many(tasks, 10_000)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      # Slow endpoint should only have been hit once even with 8 concurrent
      # resolvers — the rest piggy-back on the in-flight resolution.
      assert Agent.get(counter, & &1)["/slow"] == 1
    end

    test "stop_fn short-circuits the chain", %{base: base, counter: counter} do
      stop_fn = fn next -> String.contains?(next, "/r2") end

      assert {:ok, final} = RedirectResolver.resolve("#{base}/r1", stop_fn: stop_fn)
      assert final == "#{base}/r2"
      # /r2 itself was never fetched — we stopped at the redirect that
      # pointed to it.
      assert Map.get(Agent.get(counter, & &1), "/r2") in [nil, 0]
    end

    test "non-2xx terminal status returns {:error, {:unexpected_status, code}}", %{base: base} do
      capture_log(fn ->
        assert {:error, {:unexpected_status, 500}} = RedirectResolver.resolve("#{base}/boom")
      end)
    end

    test "missing Location header on redirect returns :missing_location", %{base: base} do
      assert {:error, :missing_location} = RedirectResolver.resolve("#{base}/headless-redirect")
    end

    test "percent-encodes redirect path spaces without changing the query", %{
      base: base,
      counter: counter
    } do
      assert {:ok, final} = RedirectResolver.resolve("#{base}/spaced-redirect")

      assert final ==
               "#{base}/2%20Fast%202%20Furious.mp4?login=firevods&stream_id=3333506&token=opaque"

      assert Agent.get(counter, & &1)["/2%20Fast%202%20Furious.mp4"] == 1
    end
  end

  describe "prewarm_async/2" do
    test "populates the cache so subsequent resolve/2 is a hit", %{base: base, counter: counter} do
      :ok = RedirectResolver.prewarm_async("#{base}/r1")

      # The request proves the prewarm task owns the single-flight slot.
      # resolve/2 now waits on that same work instead of racing a poll loop.
      assert_receive {:request_started, "/r1", _request_pid}
      assert {:ok, _final} = RedirectResolver.resolve("#{base}/r1")

      hits_after_prewarm = Agent.get(counter, & &1)

      {:ok, _} = RedirectResolver.resolve("#{base}/r1")
      assert Agent.get(counter, & &1) == hits_after_prewarm
    end
  end

  # --- Test server -----------------------------------------------------

  defp start_test_server(counter, observer) do
    {:ok, server} =
      start_supervised(
        {Bandit,
         plug: {__MODULE__.StubPlug, counter: counter, observer: observer},
         scheme: :http,
         port: 0,
         ip: :loopback,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    port
  end

  defmodule StubPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      counter = Keyword.fetch!(opts, :counter)
      observer = Keyword.fetch!(opts, :observer)
      Agent.update(counter, &Map.update(&1, conn.request_path, 1, fn n -> n + 1 end))
      send(observer, {:request_started, conn.request_path, self()})

      handle(conn, conn.request_path)
    end

    # /r1 → /r2 → /final (200)
    defp handle(conn, "/r1") do
      conn
      |> put_resp_header("location", "http://#{conn.host}:#{conn.port}/r2")
      |> send_resp(302, "")
    end

    defp handle(conn, "/r2") do
      conn
      |> put_resp_header("location", "http://#{conn.host}:#{conn.port}/final")
      |> send_resp(302, "")
    end

    defp handle(conn, "/final") do
      send_resp(conn, 200, "ok")
    end

    # /slow holds the first request open until the test releases it, so
    # concurrent callers deterministically reach the single-flight lock.
    defp handle(conn, "/slow") do
      receive do
        :release_slow_request -> send_resp(conn, 200, "ok")
      after
        2_000 -> send_resp(conn, 504, "test request timed out")
      end
    end

    # /boom → 500
    defp handle(conn, "/boom") do
      send_resp(conn, 500, "boom")
    end

    # /headless-redirect → 302 without Location
    defp handle(conn, "/headless-redirect") do
      send_resp(conn, 302, "")
    end

    defp handle(conn, "/spaced-redirect") do
      location =
        "http://#{conn.host}:#{conn.port}/2 Fast 2 Furious.mp4" <>
          "?login=firevods&stream_id=3333506&token=opaque"

      conn
      |> put_resp_header("location", location)
      |> send_resp(302, "")
    end

    defp handle(conn, "/2%20Fast%202%20Furious.mp4") do
      send_resp(conn, 200, "ok")
    end

    defp handle(conn, _other), do: send_resp(conn, 404, "")
  end
end
