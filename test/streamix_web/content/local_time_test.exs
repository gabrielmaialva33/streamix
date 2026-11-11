defmodule StreamixWeb.Content.LocalTimeTest do
  use ExUnit.Case, async: true

  alias StreamixWeb.Content.LocalTime

  test "clock shows Brasília wall-clock time" do
    assert LocalTime.clock(~U[2026-11-11 16:38:00Z]) == "13:38"
    assert LocalTime.clock(~U[2026-11-12 01:05:00Z]) == "22:05"
    assert LocalTime.clock(nil) == ""
  end

  test "day labels follow the Brasília calendar, not UTC" do
    now = ~U[2026-11-11 16:00:00Z]

    # 01:00 UTC on the 12th is still the evening of the 11th in Brasília.
    assert LocalTime.day_label(~U[2026-11-12 01:00:00Z], now) == "Hoje"
    assert LocalTime.day_label(~U[2026-11-12 04:00:00Z], now) == "Amanhã"
    assert LocalTime.day_label(~U[2026-11-10 12:00:00Z], now) == "Ontem"
    assert LocalTime.day_label(~U[2026-11-14 15:00:00Z], now) == "sáb., 14/11"
  end

  test "floor_half_hour drops to the last :00 or :30" do
    assert LocalTime.floor_half_hour(~U[2026-11-11 16:44:59Z]) == ~U[2026-11-11 16:30:00Z]
    assert LocalTime.floor_half_hour(~U[2026-11-11 16:30:00Z]) == ~U[2026-11-11 16:30:00Z]
    assert LocalTime.floor_half_hour(~U[2026-11-11 16:29:00Z]) == ~U[2026-11-11 16:00:00Z]
  end
end
