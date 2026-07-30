defmodule Streamix.Gindex.TransportTest do
  use ExUnit.Case, async: false

  alias Streamix.Gindex.Transport

  setup {Req.Test, :verify_on_exit!}

  test "retries an intermittent worker TypeError on the same endpoint" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "sync.example.com"

      Plug.Conn.send_resp(
        conn,
        500,
        "TypeError: Cannot read properties of undefined (reading 'map')"
      )
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "sync.example.com"
      Plug.Conn.send_resp(conn, 200, ~s({"data":{"files":[]}}))
    end)

    base_url = "https://sync.example.com"

    assert {:ok, %{status: 200, body: ~s({"data":{"files":[]}})}} =
             Transport.request(
               :post,
               "#{base_url}/1:/Filmes/",
               ~s({"id":"","type":"folder","password":"","page_token":null,"page_index":0}),
               base_url,
               plug: {Req.Test, __MODULE__},
               server_error_delay_ms: 0
             )
  end
end
