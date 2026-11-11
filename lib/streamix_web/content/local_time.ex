defmodule StreamixWeb.Content.LocalTime do
  @moduledoc """
  Brasília wall-clock time for what the web shows.

  Brazil has kept UTC-3 all year since 2019 and the release ships no time
  zone database (`DateTime.shift_zone!/2` would raise), so local time is a
  fixed offset from UTC. Instants stay UTC everywhere else.
  """

  @offset -3 * 3600

  @doc "A UTC instant as Brasília wall-clock time, \"17:05\"."
  @spec clock(DateTime.t() | nil) :: String.t()
  def clock(nil), do: ""
  def clock(%DateTime{} = at), do: at |> local() |> Calendar.strftime("%H:%M")

  @doc "The Brasília calendar day of a UTC instant."
  @spec date(DateTime.t()) :: Date.t()
  def date(%DateTime{} = at), do: at |> local() |> NaiveDateTime.to_date()

  @doc """
  The day of `at` said relative to `now`: "Hoje", "Amanhã", "Ontem", or
  "sex., 14/11" further out.
  """
  @spec day_label(DateTime.t(), DateTime.t()) :: String.t()
  def day_label(%DateTime{} = at, %DateTime{} = now \\ DateTime.utc_now()) do
    day = date(at)

    case Date.diff(day, date(now)) do
      0 -> "Hoje"
      1 -> "Amanhã"
      -1 -> "Ontem"
      _other -> "#{weekday(day)}, #{Calendar.strftime(day, "%d/%m")}"
    end
  end

  @doc "The latest UTC instant at or before `at` on a local :00 or :30."
  @spec floor_half_hour(DateTime.t()) :: DateTime.t()
  def floor_half_hour(%DateTime{} = at) do
    # The offset is whole hours, so UTC and local half hours coincide.
    unix = DateTime.to_unix(at)
    DateTime.from_unix!(unix - rem(unix, 1800))
  end

  defp local(at), do: at |> DateTime.add(@offset, :second) |> DateTime.to_naive()

  @weekdays ~w(seg. ter. qua. qui. sex. sáb. dom.)
  defp weekday(day), do: Enum.at(@weekdays, Date.day_of_week(day) - 1)
end
