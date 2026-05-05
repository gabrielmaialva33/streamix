defmodule Streamix.Iptv.Gindex.PacerTest do
  # Pacer talks to a shared ETS-backed rate limiter, so tests must not run
  # concurrently or one test's acquisitions leak into the next.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Streamix.Iptv.Gindex.Pacer

  setup do
    original = Application.get_env(:streamix, Pacer)

    on_exit(fn ->
      if original,
        do: Application.put_env(:streamix, Pacer, original),
        else: Application.delete_env(:streamix, Pacer)
    end)

    :ok
  end

  describe "limit_for/1" do
    test "uses the configured RPS when present" do
      Application.put_env(:streamix, Pacer, gdrive: 42, tmdb_gindex: 7)
      assert Pacer.limit_for(:gdrive) == 42
      assert Pacer.limit_for(:tmdb_gindex) == 7
    end

    test "falls back to sensible defaults for known buckets" do
      Application.delete_env(:streamix, Pacer)
      assert Pacer.limit_for(:gdrive) == 5
      assert Pacer.limit_for(:tmdb_gindex) == 10
    end
  end

  describe "acquire/1" do
    test "returns :ok under the budget" do
      Application.put_env(:streamix, Pacer, gdrive: 3)

      # Three in a row must all succeed without blocking.
      for _ <- 1..3, do: assert(Pacer.acquire(:gdrive) == :ok)
    end

    test "times out when the budget is exhausted and we won't wait" do
      Application.put_env(:streamix, Pacer, gdrive: 1)
      assert Pacer.acquire(:gdrive) == :ok

      # Second call in the same second must wait; we give it 0ms so it
      # bails out with :timeout instead of blocking the test.
      capture_log(fn ->
        assert Pacer.acquire(:gdrive, 0) == {:error, :timeout}
      end)
    end
  end
end
