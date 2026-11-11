defmodule Streamix.Programming.ScheduleTest do
  use ExUnit.Case, async: true

  alias Streamix.Programming.Schedule

  @start ~U[2026-11-11 00:00:00Z]
  @station %{
    program: [
      %{"movie_id" => 1, "duration" => 100, "title" => "A"},
      %{"movie_id" => 2, "duration" => 50, "title" => "B"},
      %{"movie_id" => 3, "duration" => 150, "title" => "C"}
    ],
    program_started_at: @start
  }

  test "finds the item, its offset and what follows" do
    slot = Schedule.at(@station, DateTime.add(@start, 120, :second))

    assert slot.index == 1
    assert slot.item["movie_id"] == 2
    assert slot.offset == 20
    assert slot.started_at == DateTime.add(@start, 100, :second)
    assert slot.ends_at == DateTime.add(@start, 150, :second)
    assert slot.next["movie_id"] == 3
    assert Schedule.progress(slot) == 0.4
  end

  test "loops: the last item is followed by the first, days later too" do
    last = Schedule.at(@station, DateTime.add(@start, 299, :second))
    assert last.item["movie_id"] == 3
    assert last.next["movie_id"] == 1

    # 300 s per loop; 3 days later lands 0 s into a loop.
    later = Schedule.at(@station, DateTime.add(@start, 3 * 86_400, :second))
    assert later.item["movie_id"] == 1 and later.offset == 0
  end

  test "every viewer asking at the same instant gets the same slot" do
    now = DateTime.add(@start, 12_345, :second)
    assert Schedule.at(@station, now) == Schedule.at(@station, now)
  end

  test "an item boundary belongs to the next item" do
    assert %{item: %{"movie_id" => 2}, offset: 0} =
             Schedule.at(@station, DateTime.add(@start, 100, :second))
  end

  test "no program, no start or no duration means nothing on air" do
    assert Schedule.at(%{@station | program: []}, @start) == nil
    assert Schedule.at(%{@station | program_started_at: nil}, @start) == nil
    assert Schedule.at(%{@station | program: [%{"movie_id" => 1}]}, @start) == nil
  end
end
