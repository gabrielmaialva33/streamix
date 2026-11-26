defmodule Streamix.Security.ClientIpTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  alias Streamix.Security.ClientIp

  setup do
    old = Application.get_env(:streamix, :trusted_proxy_cidrs, [])

    Application.put_env(
      :streamix,
      :trusted_proxy_cidrs,
      ClientIp.parse_cidrs!(["127.0.0.1/32", "2001:db8:1::/48"])
    )

    on_exit(fn -> Application.put_env(:streamix, :trusted_proxy_cidrs, old) end)
    :ok
  end

  test "walks the trusted suffix, ignores a spoofed prefix and conflicting vendor headers" do
    conn =
      Plug.Test.conn(:get, "/")
      |> put_req_header("x-forwarded-for", "192.0.2.99, 2001:DB8::2, 2001:db8:1::3")
      |> put_req_header("cf-connecting-ip", "192.0.2.98")

    assert ClientIp.from_conn(conn) == "2001:db8::2"
  end

  test "malformed or excessive forwarding chains fall back to the peer" do
    for value <- [
          "garbage",
          "192.0.2.1, bad",
          "192.0.2.1:80",
          Enum.join(List.duplicate("192.0.2.1", 33), ",")
        ] do
      assert Plug.Test.conn(:get, "/")
             |> put_req_header("x-forwarded-for", value)
             |> ClientIp.from_conn() == "127.0.0.1"
    end
  end

  test "invalid CIDRs fail configuration instead of broadening trust" do
    for value <- ["127.0.0.1", "127.0.0.1/33", "::1/129", "not-an-ip/0"] do
      assert_raise ArgumentError, fn -> ClientIp.parse_cidrs!([value]) end
    end
  end
end
