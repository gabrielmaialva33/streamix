defmodule Streamix.Gindex.QuotaGuardTest do
  use ExUnit.Case, async: true

  alias Streamix.Gindex.QuotaGuard

  describe "seconds_until_reset/1" do
    test "targets the next UTC midnight with a clock-skew buffer" do
      assert QuotaGuard.seconds_until_reset(~U[2026-07-24 23:59:55Z]) == 10
      assert QuotaGuard.seconds_until_reset(~U[2026-07-24 12:00:00Z]) == 43_205
    end
  end
end
