defmodule Streamix.Programming.Schedule do
  @moduledoc """
  What a station plays at a given instant: pure arithmetic on its program.

  The program loops from `program_started_at`, so the elapsed time modulo
  the program's total duration lands inside exactly one item. Every viewer,
  node and page asking about the same instant gets the same answer.
  """

  alias Streamix.Programming.Station

  @type slot :: %{
          index: non_neg_integer(),
          item: map(),
          offset: non_neg_integer(),
          started_at: DateTime.t(),
          ends_at: DateTime.t(),
          next: map()
        }

  @doc "The item playing at `now`, its offset in seconds and what follows; nil without a program."
  @spec at(Station.t() | map(), DateTime.t()) :: slot() | nil
  def at(%{program: program, program_started_at: %DateTime{} = started}, %DateTime{} = now)
      when is_list(program) and program != [] do
    total = Enum.reduce(program, 0, &(&2 + duration(&1)))

    if total == 0 do
      nil
    else
      elapsed = Integer.mod(DateTime.diff(now, started, :second), total)
      {index, item_start} = locate(program, elapsed)
      item = Enum.at(program, index)
      offset = elapsed - item_start
      remaining = duration(item) - offset

      %{
        index: index,
        item: item,
        offset: offset,
        started_at: DateTime.add(now, -offset, :second),
        ends_at: DateTime.add(now, remaining, :second),
        next: Enum.at(program, rem(index + 1, length(program)))
      }
    end
  end

  def at(_station, _now), do: nil

  @doc "Share of the current item already played, 0.0 to 1.0."
  @spec progress(slot()) :: float()
  def progress(%{item: item, offset: offset}) do
    case duration(item) do
      0 -> 0.0
      total -> Float.round(offset / total, 4)
    end
  end

  defp locate(program, elapsed) do
    program
    |> Enum.with_index()
    |> Enum.reduce_while(0, fn {item, index}, start ->
      finish = start + duration(item)
      if elapsed < finish, do: {:halt, {index, start}}, else: {:cont, finish}
    end)
  end

  defp duration(%{"duration" => seconds}) when is_integer(seconds) and seconds > 0, do: seconds
  defp duration(_item), do: 0
end
