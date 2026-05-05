defmodule Streamix.Iptv.Streaming.StreamErrorsTest do
  use StreamixWeb.ConnCase, async: true

  alias Streamix.Iptv.Streaming.StreamErrors

  describe "halt/3" do
    test "emits the canonical stream error JSON body" do
      conn =
        build_conn(:get, "/any")
        |> StreamErrors.halt(:upstream_unavailable)

      assert conn.status == 502
      assert conn.halted

      body = Phoenix.ConnTest.json_response(conn, 502)
      assert body["error"]["code"] == "upstream_unavailable"
      assert body["error"]["message"] == "Provider backend is currently unavailable"
      assert body["error"]["retry_after"] == 120
    end
  end

  describe "code_from_reason/1" do
    test "maps upstream and transport reasons to canonical codes" do
      assert StreamErrors.code_from_reason({:unexpected_status, 404}) == :upstream_not_found
      assert StreamErrors.code_from_reason({:unexpected_status, 502}) == :upstream_unavailable
      assert StreamErrors.code_from_reason(:timeout) == :upstream_timeout

      assert StreamErrors.code_from_reason(%Req.TransportError{reason: :econnrefused}) ==
               :upstream_unavailable
    end
  end
end
