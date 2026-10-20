defmodule StreamixWeb.Helpers.Money do
  @moduledoc """
  Prices as a pt-BR reader expects them ("R$ 1.234,56"), in the currency they
  are stored in. Only the number is localized: a USD plan stays in dollars.
  """

  @symbols %{"BRL" => "R$", "USD" => "US$", "EUR" => "€"}

  @doc """
      iex> StreamixWeb.Helpers.Money.format(123_456, "BRL")
      "R$ 1.234,56"
      iex> StreamixWeb.Helpers.Money.format(1000, "USD")
      "US$ 10,00"
  """
  @spec format(integer() | nil, String.t() | nil) :: String.t()
  def format(cents, currency \\ "BRL")

  def format(cents, currency) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    cents = abs(cents)
    units = cents |> div(100) |> Integer.to_string() |> group_thousands()
    decimals = cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")

    "#{sign}#{symbol(currency)} #{units},#{decimals}"
  end

  def format(nil, currency), do: format(0, currency)

  defp symbol(nil), do: "R$"
  defp symbol(currency), do: Map.get(@symbols, String.upcase(currency), String.upcase(currency))

  defp group_thousands(digits) do
    digits
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(".", &Enum.join/1)
    |> String.reverse()
  end
end
