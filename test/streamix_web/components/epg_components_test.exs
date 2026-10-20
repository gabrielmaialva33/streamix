defmodule StreamixWeb.EpgComponentsTest do
  use ExUnit.Case, async: true
  alias StreamixWeb.EpgComponents

  test "programme geometry preserves duration and clamps both window boundaries" do
    starts_at = ~U[2026-10-20 12:00:00Z]
    ends_at = DateTime.add(starts_at, 180, :minute)

    for {start, stop, left, width} <- [
          {-60, 45, 0.0, 25.0},
          {45, 135, 25.0, 50.0},
          {135, 240, 75.0, 25.0},
          {-60, 240, 0.0, 100.0},
          {180, 240, 100.0, 0.0}
        ] do
      program = %{
        start_time: DateTime.add(starts_at, start, :minute),
        end_time: DateTime.add(starts_at, stop, :minute)
      }

      assert EpgComponents.program_style(program, starts_at, ends_at) ==
               "--program-left: #{left}%; --program-width: #{width}%;"
    end
  end
end
