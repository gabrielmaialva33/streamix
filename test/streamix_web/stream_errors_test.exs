defmodule StreamixWeb.StreamErrorsTest do
  use StreamixWeb.ConnCase, async: true

  alias StreamixWeb.StreamErrors

  describe "halt/3" do
    test "emits the canonical shape with code + message for a known code" do
      conn =
        build_conn(:get, "/any")
        |> StreamErrors.halt(:content_not_found)

      assert conn.status == 404
      assert conn.halted
      # The TV client pins on :code — it's the machine-readable identifier
      # that survives wording tweaks in :message.
      body = Phoenix.ConnTest.json_response(conn, 404)
      assert body["error"]["code"] == "content_not_found"
      assert body["error"]["message"] == "Content not found"
      refute Map.has_key?(body["error"], "retry_after")
    end

    test "attaches retry_after for transient upstream failures" do
      # A TV client seeing `retry_after` knows to auto-retry silently;
      # its absence means "don't bother, this is terminal".
      conn =
        build_conn(:get, "/any")
        |> StreamErrors.halt(:upstream_unavailable)

      body = Phoenix.ConnTest.json_response(conn, 502)
      assert body["error"]["code"] == "upstream_unavailable"
      assert body["error"]["retry_after"] == 120
    end

    test "lets the caller override the human message without touching the code/retry" do
      # Controllers sometimes have more specific copy (e.g. "returned
      # HTTP 503"). The :code stays canonical so switch/case in the
      # client keeps working.
      conn =
        build_conn(:get, "/any")
        |> StreamErrors.halt(:upstream_timeout,
          override_message: "Provider timed out after 15s"
        )

      body = Phoenix.ConnTest.json_response(conn, 504)
      assert body["error"]["code"] == "upstream_timeout"
      assert body["error"]["message"] == "Provider timed out after 15s"
      assert body["error"]["retry_after"] == 60
    end

    test "unknown codes fall back to a generic 400" do
      # A terminal default keeps future typos from 500'ing the whole
      # response pipeline.
      conn =
        build_conn(:get, "/any")
        |> StreamErrors.halt(:definitely_not_a_code)

      assert conn.status == 400
      body = Phoenix.ConnTest.json_response(conn, 400)
      assert body["error"]["code"] == "definitely_not_a_code"
    end

    test "uses a canonical 401 response for internal authorization failures" do
      conn =
        build_conn(:get, "/any")
        |> StreamErrors.halt(:unauthorized)

      assert conn.status == 401
      assert conn.halted

      assert %{"error" => %{"code" => "unauthorized", "message" => "Unauthorized"}} =
               Phoenix.ConnTest.json_response(conn, 401)
    end
  end

  describe "code_from_reason/1" do
    test "maps upstream 404 to :upstream_not_found" do
      assert StreamErrors.code_from_reason({:unexpected_status, 404}) == :upstream_not_found
    end

    test "maps any 5xx status to :upstream_unavailable" do
      # The actual provider outage that motivated this module returned
      # 502 from the upstream; 503/504 are the same class of failure
      # and should map onto the same code.
      assert StreamErrors.code_from_reason({:unexpected_status, 500}) == :upstream_unavailable
      assert StreamErrors.code_from_reason({:unexpected_status, 502}) == :upstream_unavailable
      assert StreamErrors.code_from_reason({:unexpected_status, 503}) == :upstream_unavailable
    end

    test "maps transport timeouts explicitly" do
      assert StreamErrors.code_from_reason(:timeout) == :upstream_timeout

      assert StreamErrors.code_from_reason(%Req.TransportError{reason: :timeout}) ==
               :upstream_timeout
    end

    test "any other transport error goes to :upstream_unavailable" do
      # :econnrefused / :nxdomain / :closed all become the same
      # retriable bucket — the TV app doesn't need finer granularity
      # than "provider is not responding right now".
      assert StreamErrors.code_from_reason(%Req.TransportError{reason: :econnrefused}) ==
               :upstream_unavailable
    end

    test "falls back to :stream_resolution_failed for unknown shapes" do
      assert StreamErrors.code_from_reason(:something_weird) == :stream_resolution_failed
    end
  end
end
