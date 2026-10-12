defmodule Streamix.Embedplay.HTTPTest do
  use ExUnit.Case, async: false

  alias Streamix.Embedplay.HTTP

  setup do
    original = Application.get_env(:streamix, :embedplay, [])
    Application.put_env(:streamix, :embedplay, http_options: [plug: {Req.Test, __MODULE__}])
    on_exit(fn -> Application.put_env(:streamix, :embedplay, original) end)
  end

  describe "resolve/1 error classification" do
    # The resolver answers 502 for several failures at once. Splitting them
    # is about countability and backoff, NOT about declaring titles dead:
    # `stream_unavailable` is raised whenever extraction failed, and the causes
    # seen in production were environmental (an offered host answering 403 from
    # this server; another yielding no fetchable manifest). Every case below
    # therefore stays retryable.
    setup do
      config = Application.get_env(:streamix, :embedplay)

      Application.put_env(
        :streamix,
        :embedplay,
        config ++ [resolver_url: "http://127.0.0.1:9999", resolver_token: "test-only"]
      )

      %{movie: %Streamix.Iptv.Movie{tmdb_id: "10010", imdb_id: "tt0465925"}}
    end

    defp respond(status, body) do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, body)
      end)
    end

    test "a failed extraction is classified apart, and stays retryable", %{movie: movie} do
      respond(502, ~s({"error":{"code":"stream_unavailable"}}))
      assert {:error, :no_source_available} = HTTP.resolve(movie)
    end

    # A challenge is never solved, so the health monitor has to be able to
    # count it; the generic failure would be filed as transient.
    test "a challenge is classified apart so health can count it", %{movie: movie} do
      respond(502, ~s({"error":{"code":"challenge_required"}}))
      assert {:error, :challenge_required} = HTTP.resolve(movie)
    end

    test "an unparseable error body falls back to the generic failure", %{movie: movie} do
      respond(502, "<html>upstream exploded</html>")
      assert {:error, :stream_resolution_failed} = HTTP.resolve(movie)
    end

    # `unsupported_page` means the resolver's adapter no longer matches the
    # upstream page at all — systemic, not per-title. A health monitor keys on
    # this exact atom.
    test "an outdated resolver adapter is classified as systemic", %{movie: movie} do
      respond(502, ~s({"error":{"code":"unsupported_page"}}))
      assert {:error, :resolver_outdated} = HTTP.resolve(movie)
    end

    test "documented statuses keep their own meanings", %{movie: movie} do
      for {status, expected} <- [
            {503, :provider_capacity_exhausted},
            {504, :upstream_timeout},
            {401, :provider_disabled}
          ] do
        respond(status, ~s({"error":{"code":"stream_unavailable"}}))

        assert {:error, ^expected} = HTTP.resolve(movie),
               "status #{status} must not be reclassified by the body"
      end
    end
  end

  describe "resolve/1 media contract" do
    setup do
      config = Application.get_env(:streamix, :embedplay)

      Application.put_env(
        :streamix,
        :embedplay,
        config ++ [resolver_url: "http://127.0.0.1:9999", resolver_token: "test-only"]
      )

      %{movie: %Streamix.Iptv.Movie{tmdb_id: "603", imdb_id: "tt0133093"}}
    end

    defp resolve_with(movie, body) do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, body))
      HTTP.resolve(movie)
    end

    test "decodes a progressive MP4 source with its referer and user agent", %{movie: movie} do
      assert {:ok, source} =
               resolve_with(movie, %{
                 kind: "mp4",
                 media_url: "https://93.184.216.34/sora/123/token",
                 expires_at: nil,
                 headers: %{
                   "referer" => "https://abysscdn.com/",
                   "user-agent" => "Mozilla/5.0 Test"
                 }
               })

      assert source.kind == :mp4
      assert source.url == "https://93.184.216.34/sora/123/token"
      assert source.expires_at == nil

      assert Enum.sort(source.headers) == [
               {"referer", "https://abysscdn.com/"},
               {"user-agent", "Mozilla/5.0 Test"}
             ]
    end

    test "decodes an HLS source on the new contract", %{movie: movie} do
      url = "https://93.184.216.34/root/master.m3u8"

      assert {:ok, %{kind: :hls, url: ^url, expires_at: "2026-10-12T20:00:00Z"}} =
               resolve_with(movie, %{
                 kind: "hls",
                 media_url: url,
                 manifest_url: url,
                 expires_at: "2026-10-12T20:00:00Z",
                 headers: %{}
               })
    end

    # The deployed resolver answers this way until it is redeployed; either
    # side must be able to ship first.
    test "reads a legacy manifest-only answer as HLS", %{movie: movie} do
      url = "https://93.184.216.34/root/master.m3u8"

      assert {:ok, %{kind: :hls, url: ^url, headers: []}} =
               resolve_with(movie, %{manifest_url: url, headers: %{}})
    end

    test "refuses unknown kinds, missing URLs and unsafe media URLs", %{movie: movie} do
      for body <- [
            %{kind: "dash", media_url: "https://93.184.216.34/movie.mpd"},
            %{kind: "mp4"},
            %{kind: "mp4", manifest_url: "https://93.184.216.34/movie.mp4"},
            %{kind: "mp4", media_url: "https://127.0.0.1/movie.mp4"},
            %{kind: "mp4", media_url: "file:///etc/passwd"}
          ] do
        assert {:error, :stream_resolution_failed} = resolve_with(movie, body),
               "accepted #{inspect(body)}"
      end
    end
  end

  describe "stream/5" do
    @referer {"referer", "https://abysscdn.com/"}
    @agent {"user-agent", "Mozilla/5.0 Test"}

    defp collect, do: fn event, events -> {:cont, [event | events]} end

    test "follows the redirect to the tunnel host, sending the source headers on every hop" do
      owner = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(owner, {:hop, conn.host, conn.request_path, conn.req_headers})

        case conn.host do
          "93.184.216.34" ->
            conn
            |> Plug.Conn.put_resp_header("location", "https://104.16.0.1/media/movie.mp4")
            |> Plug.Conn.send_resp(302, "redirect body the sink must never see")

          "104.16.0.1" ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "video/mp4")
            |> Plug.Conn.put_resp_header("content-range", "bytes 0-3/100")
            |> Plug.Conn.send_resp(206, "abcd")
        end
      end)

      assert {:ok, events} =
               HTTP.stream(
                 "https://93.184.216.34/sora/123/token",
                 [@referer, @agent],
                 [range: "bytes=0-3"],
                 [],
                 collect()
               )

      assert [{:start, 206, headers}, {:data, "abcd"}] = Enum.reverse(events)
      assert headers["content-range"] == ["bytes 0-3/100"]

      for host <- ["93.184.216.34", "104.16.0.1"] do
        assert_received {:hop, ^host, _path, req_headers}
        assert {"referer", "https://abysscdn.com/"} in req_headers
        assert {"user-agent", "Mozilla/5.0 Test"} in req_headers
        assert {"range", "bytes=0-3"} in req_headers
        refute List.keymember?(req_headers, "origin", 0)
      end
    end

    test "a halting sink stops reading the upstream body" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(["one", "two", "three"], conn, fn part, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, part)
          conn
        end)
      end)

      halt_after_first = fn
        {:start, _status, _headers}, events -> {:cont, events}
        {:data, data}, events -> {:halt, [data | events]}
      end

      assert {:ok, ["one"]} =
               HTTP.stream("https://93.184.216.34/movie.mp4", [], [], [], halt_after_first)
    end

    test "classifies error statuses without starting the response" do
      for {status, reason} <- [
            {403, :playback_restart_required},
            {410, :playback_restart_required},
            {404, :upstream_not_found},
            {416, :invalid_range},
            {500, :upstream_unavailable}
          ] do
        Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, status, "cloudflare page"))

        assert {:error, ^reason} =
                 HTTP.stream("https://93.184.216.34/movie.mp4", [], [], [], fn _event, _acc ->
                   flunk("an error response reached the client sink")
                 end)
      end
    end

    test "a sink can still refuse the response before anything is sent" do
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, "bytes"))

      refuse = fn {:start, 200, _headers}, _acc -> {:error, :upstream_unavailable} end

      assert {:error, :upstream_unavailable} =
               HTTP.stream("https://93.184.216.34/movie.mp4", [], [], [], refuse)
    end

    test "validates every redirect hop before requesting it" do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://127.0.0.1/secret.mp4")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, :unsafe_url} =
               HTTP.stream("https://93.184.216.34/movie.mp4", [], [], [], collect())
    end
  end

  test "checks every redirect and blocks a public-to-private redirect before requesting it" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "93.184.216.34"

      conn
      |> Plug.Conn.put_resp_header("location", "http://127.0.0.1/secret")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, :unsafe_url} = HTTP.fetch("https://93.184.216.34/start", [])
  end

  test "does not forward arbitrary auth headers or caller URLs through resolver output" do
    config = Application.get_env(:streamix, :embedplay)

    Application.put_env(
      :streamix,
      :embedplay,
      config ++ [resolver_url: "http://127.0.0.1:9999", resolver_token: "test-only"]
    )

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        manifest_url: "https://93.184.216.34/master.m3u8",
        headers: %{authorization: "private-upstream-secret"}
      })
    end)

    assert {:error, :stream_resolution_failed} = HTTP.resolve(%{tmdb_id: "603", imdb_id: nil})
  end

  test "bounded body collection rejects oversized resources" do
    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 200, :binary.copy(<<0>>, 32 * 1024 * 1024 + 1))
    end)

    assert {:error, :response_too_large} = HTTP.fetch("https://93.184.216.34/large.ts", [])
  end
end
