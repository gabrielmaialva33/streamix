defmodule Streamix.Ecto.InetTest do
  use ExUnit.Case, async: true

  alias Streamix.Ecto.Inet

  describe "cast/1" do
    test "accepts valid IPv4 and IPv6 strings" do
      assert Inet.cast("127.0.0.1") == {:ok, "127.0.0.1"}
      assert Inet.cast("2001:db8::1") == {:ok, "2001:db8::1"}
    end

    test "rejects malformed addresses instead of raising" do
      assert Inet.cast("not-an-ip") == :error
    end
  end

  describe "dump/1" do
    test "converts valid strings to Postgrex.INET values" do
      assert {:ok, %Postgrex.INET{address: {127, 0, 0, 1}}} = Inet.dump("127.0.0.1")
    end

    test "rejects malformed addresses instead of raising" do
      assert Inet.dump("999.999.999.999") == :error
    end
  end
end
