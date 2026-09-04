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

      assert :miss = RedirectResolver.peek("#{base}/r1")

      assert_raise ArgumentError, fn ->
        RedirectResolver.peek("#{base}/r1", stop_fn: stop_fn)
      end

      expected_full = "#{base}/final"
      assert {:ok, ^expected_full} = RedirectResolver.resolve("#{base}/r1")
      assert Agent.get(counter, &Map.get(&1, "/r2", 0)) == 1
    end

    test "explicit policy scopes preserve single-flight and remain independently peekable", %{
      base: base,
      counter: counter
    } do
      slow = "#{base}/slow"

      tasks =
        for _ <- 1..4 do
          Task.async(fn ->
            RedirectResolver.resolve(slow,
              cache_scope: :partial_test,
              stop_fn: fn _next_url -> true end
            )
          end)
        end

      assert_receive {:request_started, "/slow", request_pid}
      send(request_pid, :release_slow_request)
      assert Enum.all?(Task.await_many(tasks, 10_000), &match?({:ok, _}, &1))
      assert Agent.get(counter, & &1)["/slow"] == 1
      assert :miss = RedirectResolver.peek(slow)
      assert {:ok, ^slow} = RedirectResolver.peek(slow, cache_scope: :partial_test)
    end

    test "non-2xx terminal status returns {:error, {:unexpected_status, code}}", %{base: base} do
      capture_log(fn ->
        assert {:error, {:unexpected_status, 500}} = RedirectResolver.resolve("#{base}/boom")
      end)
    end

    test "rejects a 2xx that carries a web page instead of media", %{base: base} do
      # Field case: the provider's CDN cached an empty text/html body for a
      # movie. Accepting it made the proxy serve zero bytes with no length,
      # and the player hung until it died with `open stream failed`.
      capture_log(fn ->
        assert {:error, {:not_media, content_type}} =
                 RedirectResolver.resolve("#{base}/empty-html")

        assert content_type =~ "text/html"
      end)
    end

    test "rejects a non-media page reached at the end of a redirect chain", %{base: base} do
      capture_log(fn ->
        assert {:error, {:not_media, _}} = RedirectResolver.resolve("#{base}/redirect-to-html")
      end)
    end

    test "does not retry a non-media response — the answer will not change",
         %{base: base, counter: counter} do
      capture_log(fn ->
        assert {:error, {:not_media, _}} = RedirectResolver.resolve("#{base}/empty-html")
      end)

      assert Agent.get(counter, & &1)["/empty-html"] == 1
    end

    test "still accepts a 2xx that carries real media", %{base: base} do
      assert {:ok, final} = RedirectResolver.resolve("#{base}/real-media")
      assert final == "#{base}/real-media"
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

  describe "SSRF guard" do
    test "refuses a scheme the proxy must never follow" do
      log =
        capture_log(fn ->
          assert {:error, :unsafe_url} =
                   RedirectResolver.resolve("file:///etc/passwd", allow_private_network: false)
        end)

      assert log =~ "SSRF blocked"
    end

    test "refuses a loopback target when private networks are not allowed", %{base: base} do
      # The suite relaxes this globally so fixtures on 127.0.0.1 work; the
      # explicit option is what production runs with.
      log =
        capture_log(fn ->
          assert {:error, :unsafe_url} =
                   RedirectResolver.resolve("#{base}/r1", allow_private_network: false)
        end)

      assert log =~ "SSRF blocked"
    end

    test "validates every hop, not just the URL the chain starts from", %{base: base} do
      # The entry URL is accepted (the suite allows loopback), so a refusal
      # here can only come from checking the redirect target itself.
      log =
        capture_log(fn ->
          assert {:error, :unsafe_url} = RedirectResolver.resolve("#{base}/hostile-hop")
        end)

      assert log =~ "SSRF blocked"
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

    test "partial prewarm safely seeds a later full-chain resolution", %{
      base: base,
      counter: counter
    } do
      source = "#{base}/movie/test-user/test-password/stream.ts"
      token = "#{base}/single-use-token"
      final = "#{base}/final-media"

      :ok = RedirectResolver.prewarm_for_proxy_async(source)
      assert_receive {:request_started, "/movie/test-user/test-password/stream.ts", _request_pid}

      assert {:ok, ^token} = RedirectResolver.resolve_for_proxy(source)
      assert Agent.get(counter, &Map.get(&1, "/single-use-token", 0)) == 0
      assert :miss = RedirectResolver.peek(source)

      assert {:ok, ^token} =
               RedirectResolver.peek(source, cache_scope: :credential_exchange)

      assert {:ok, ^final} = RedirectResolver.resolve(source)
      # Full resolution resumes from the cached credential-free hop. The
      # credential-bearing origin is not fetched twice, and the token target
      # is still consumed only by the real full-chain request.
      assert Agent.get(counter, &Map.get(&1, "/movie/test-user/test-password/stream.ts", 0)) == 1
      assert Agent.get(counter, &Map.get(&1, "/single-use-token", 0)) == 1
      assert Agent.get(counter, &Map.get(&1, "/final-media", 0)) == 1
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

    # A hop that tries to walk the proxy off HTTP entirely.
    defp handle(conn, "/hostile-hop") do
      conn
      |> put_resp_header("location", "file:///etc/passwd")
      |> send_resp(302, "")
    end

    defp handle(conn, "/movie/test-user/test-password/stream.ts") do
      conn
      |> put_resp_header("location", "http://#{conn.host}:#{conn.port}/single-use-token")
      |> send_resp(302, "")
    end

    defp handle(conn, "/single-use-token") do
      conn
      |> put_resp_header("location", "http://#{conn.host}:#{conn.port}/final-media")
      |> send_resp(302, "")
    end

    defp handle(conn, "/final-media") do
      conn
      |> put_resp_content_type("video/mp4")
      |> send_resp(200, "media")
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

    # A CDN-cached empty error page: 200, text/html, no body. This is what
    # the provider serves for a poisoned cache entry.
    defp handle(conn, "/empty-html") do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, "")
    end

    # 200 that really is media — must still resolve.
    defp handle(conn, "/real-media") do
      conn
      |> put_resp_content_type("video/mp4")
      |> send_resp(200, "binary-ish")
    end

    # Redirect chain that ends on the poisoned HTML page.
    defp handle(conn, "/redirect-to-html") do
      conn
      |> put_resp_header("location", "http://#{conn.host}:#{conn.port}/empty-html")
      |> send_resp(302, "")
    end

    defp handle(conn, _other), do: send_resp(conn, 404, "")
  end
end
