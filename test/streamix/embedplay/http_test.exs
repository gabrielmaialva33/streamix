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

    test "a challenge keeps the generic retryable classification", %{movie: movie} do
      respond(502, ~s({"error":{"code":"challenge_required"}}))
      assert {:error, :stream_resolution_failed} = HTTP.resolve(movie)
    end

    test "an unparseable error body falls back to the generic failure", %{movie: movie} do
      respond(502, "<html>upstream exploded</html>")
      assert {:error, :stream_resolution_failed} = HTTP.resolve(movie)
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
