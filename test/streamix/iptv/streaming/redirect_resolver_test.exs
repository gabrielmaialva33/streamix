defmodule Streamix.Iptv.Streaming.RedirectResolverTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Streamix.Iptv.Streaming.RedirectResolver

  setup do
    RedirectResolver.clear_cache()
    counter = start_supervised!({Agent, fn -> %{} end})
    port = start_test_server(counter)
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
  end

  describe "prewarm_async/2" do
    test "populates the cache so subsequent resolve/2 is a hit", %{base: base, counter: counter} do
      :ok = RedirectResolver.prewarm_async("#{base}/r1")

      # Wait until the prewarm task finishes — bounded poll on the cache.
      assert eventually(fn ->
               match?(
                 {:ok, _},
                 RedirectResolver.resolve("#{base}/r1")
               )
             end)

      hits_after_prewarm = Agent.get(counter, & &1)

      {:ok, _} = RedirectResolver.resolve("#{base}/r1")
      assert Agent.get(counter, & &1) == hits_after_prewarm
    end
  end

  # --- Test server -----------------------------------------------------

  defp start_test_server(counter) do
    {:ok, server} =
      start_supervised(
        {Bandit,
         plug: {__MODULE__.StubPlug, counter: counter},
         scheme: :http,
         port: 0,
         ip: :loopback,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    port
  end

  defp eventually(fun, deadline \\ 2_000) do
    deadline_at = System.monotonic_time(:millisecond) + deadline
    do_eventually(fun, deadline_at)
  end

  defp do_eventually(fun, deadline_at) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) > deadline_at do
        false
      else
        Process.sleep(25)
        do_eventually(fun, deadline_at)
      end
    end
  end

  defmodule StubPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      counter = Keyword.fetch!(opts, :counter)
      Agent.update(counter, &Map.update(&1, conn.request_path, 1, fn n -> n + 1 end))

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

    # /slow → final (200) but with a small delay so concurrent callers
    # genuinely race the lock instead of finishing before the second
    # resolver reaches lookup/1.
    defp handle(conn, "/slow") do
      Process.sleep(150)
      send_resp(conn, 200, "ok")
    end

    # /boom → 500
    defp handle(conn, "/boom") do
      send_resp(conn, 500, "boom")
    end

    # /headless-redirect → 302 without Location
    defp handle(conn, "/headless-redirect") do
      send_resp(conn, 302, "")
    end

    defp handle(conn, _other), do: send_resp(conn, 404, "")
  end
end
