defmodule Streamix.Embedplay.HTTPTest do
  use ExUnit.Case, async: false

  alias Streamix.Embedplay.HTTP

  setup do
    original = Application.get_env(:streamix, :embedplay, [])
    Application.put_env(:streamix, :embedplay, http_options: [plug: {Req.Test, __MODULE__}])
    on_exit(fn -> Application.put_env(:streamix, :embedplay, original) end)
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
