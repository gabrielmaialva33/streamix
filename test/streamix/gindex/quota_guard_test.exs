defmodule Streamix.Gindex.QuotaGuardTest do
  use ExUnit.Case, async: false

  alias Streamix.Gindex.QuotaGuard

  setup do
    original = Application.get_env(:streamix, QuotaGuard)
    quota_key = "gindex:quota:#{Date.utc_today()}"

    Application.put_env(:streamix, QuotaGuard,
      daily_limit: 5,
      playback_reserve: 2
    )

    Redix.command!(:streamix_redis, ["DEL", quota_key])

    on_exit(fn ->
      Redix.command!(:streamix_redis, ["DEL", quota_key])

      if original do
        Application.put_env(:streamix, QuotaGuard, original)
      else
        Application.delete_env(:streamix, QuotaGuard)
      end
    end)

    %{quota_key: quota_key}
  end

  describe "seconds_until_reset/1" do
    test "targets the next UTC midnight with a clock-skew buffer" do
      assert QuotaGuard.seconds_until_reset(~U[2026-07-24 23:59:55Z]) == 10
      assert QuotaGuard.seconds_until_reset(~U[2026-07-24 12:00:00Z]) == 43_205
    end
  end

  test "reserves the tail of the shared hard limit for playback" do
    assert {:ok, :ok, 1} = QuotaGuard.consume(:background)
    assert {:ok, :ok, 2} = QuotaGuard.consume(:background)
    assert {:ok, :warning, 3} = QuotaGuard.consume(:background)

    assert {:error, :exhausted, 3} = QuotaGuard.consume(:background)

    assert {:ok, :warning, 4} = QuotaGuard.consume(:playback)
    assert {:ok, :warning, 5} = QuotaGuard.consume(:playback)
    assert {:error, :exhausted, 5} = QuotaGuard.consume(:playback)

    assert %{
             count: 5,
             limit: 5,
             remaining: 0,
             background_limit: 3,
             background_remaining: 0,
             playback_reserve: 2
           } = QuotaGuard.status()
  end

  test "keeps concurrent playback reservations under the atomic hard limit" do
    results =
      1..20
      |> Task.async_stream(fn _ -> QuotaGuard.consume(:playback) end,
        max_concurrency: 20,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _, _}, &1)) == 5
    assert Enum.count(results, &match?({:error, :exhausted, 5}, &1)) == 15
    assert QuotaGuard.current_count() == 5
  end

  test "rejects a reserve that would eliminate the background budget" do
    Application.put_env(:streamix, QuotaGuard, daily_limit: 5, playback_reserve: 5)

    assert_raise ArgumentError, ~r/playback_reserve/, fn ->
      QuotaGuard.policy()
    end
  end
end
