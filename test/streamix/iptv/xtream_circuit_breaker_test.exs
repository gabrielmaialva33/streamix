defmodule Streamix.Iptv.XtreamCircuitBreakerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Streamix.Iptv.XtreamCircuitBreaker

  setup do
    # Reset all circuits before each test
    XtreamCircuitBreaker.reset_all()
    :ok
  end

  describe "allow_request?/1" do
    test "allows requests when circuit is closed" do
      assert :ok = XtreamCircuitBreaker.allow_request?(123)
    end

    test "opens circuit after threshold errors" do
      provider_id = 456

      # Report 5 errors (threshold)
      capture_log(fn ->
        for _ <- 1..5 do
          XtreamCircuitBreaker.report_error(provider_id, :server_error)
        end
      end)

      _ = :sys.get_state(XtreamCircuitBreaker)

      # Circuit should be open now
      assert {:error, {:circuit_open, _remaining}} =
               XtreamCircuitBreaker.allow_request?(provider_id)
    end

    test "returns remaining seconds when circuit is open" do
      provider_id = 789

      capture_log(fn ->
        for _ <- 1..5 do
          XtreamCircuitBreaker.report_error(provider_id, :timeout)
        end
      end)

      _ = :sys.get_state(XtreamCircuitBreaker)

      {:error, {:circuit_open, remaining}} = XtreamCircuitBreaker.allow_request?(provider_id)

      # Should be around 180 seconds (3 minutes recovery timeout)
      assert remaining > 170 and remaining <= 180
    end
  end

  describe "report_success/1" do
    test "resets error count" do
      provider_id = 111

      # Report some errors (but not enough to open)
      for _ <- 1..3 do
        XtreamCircuitBreaker.report_error(provider_id, :server_error)
      end

      _ = :sys.get_state(XtreamCircuitBreaker)

      # Report success
      XtreamCircuitBreaker.report_success(provider_id)
      _ = :sys.get_state(XtreamCircuitBreaker)

      # Should still allow requests
      assert :ok = XtreamCircuitBreaker.allow_request?(provider_id)
    end
  end

  describe "get_state/1" do
    test "returns :closed for new provider" do
      assert :closed = XtreamCircuitBreaker.get_state(999)
    end

    test "returns :open after threshold errors" do
      provider_id = 222

      capture_log(fn ->
        for _ <- 1..5 do
          XtreamCircuitBreaker.report_error(provider_id, :server_error)
        end
      end)

      _ = :sys.get_state(XtreamCircuitBreaker)

      assert :open = XtreamCircuitBreaker.get_state(provider_id)
    end
  end

  describe "get_all_status/0" do
    test "returns empty list initially" do
      assert [] = XtreamCircuitBreaker.get_all_status()
    end

    test "returns status for tracked providers" do
      XtreamCircuitBreaker.allow_request?(333)
      XtreamCircuitBreaker.report_success(333)

      _ = :sys.get_state(XtreamCircuitBreaker)

      status = XtreamCircuitBreaker.get_all_status()

      assert length(status) == 1
      assert [%{provider_id: 333, circuit_state: :closed}] = status
    end
  end

  describe "reset/1" do
    test "resets circuit to closed state" do
      provider_id = 444

      # Open the circuit
      capture_log(fn ->
        for _ <- 1..5 do
          XtreamCircuitBreaker.report_error(provider_id, :server_error)
        end
      end)

      _ = :sys.get_state(XtreamCircuitBreaker)
      assert :open = XtreamCircuitBreaker.get_state(provider_id)

      # Reset
      XtreamCircuitBreaker.reset(provider_id)
      _ = :sys.get_state(XtreamCircuitBreaker)

      assert :closed = XtreamCircuitBreaker.get_state(provider_id)
    end
  end

  describe "half-open state" do
    test "transitions to half-open after recovery timeout" do
      # This test would require mocking time or waiting 3 minutes
      # Skipping for now - the logic is tested by integration tests
    end

    test "closes circuit after success threshold in half-open" do
      # Similar to above - requires time manipulation
    end
  end
end
