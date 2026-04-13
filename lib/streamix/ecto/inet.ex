defmodule Streamix.Ecto.Inet do
  @moduledoc """
  Custom Ecto type for PostgreSQL `inet` columns.

  Stores IP addresses as strings in Elixir but maps to/from
  Postgrex.INET structs at the database level.
  """

  use Ecto.Type

  def type, do: :inet

  # From Elixir to Ecto changesets — accept strings
  def cast(ip) when is_binary(ip) do
    case parse_ip(ip) do
      {:ok, _tuple} -> {:ok, ip}
      :error -> :error
    end
  end

  def cast(%Postgrex.INET{address: addr}) do
    {:ok, format_ip(addr)}
  end

  def cast(nil), do: {:ok, nil}
  def cast(_), do: :error

  # From Elixir to DB — convert string to Postgrex.INET
  def dump(nil), do: {:ok, nil}

  def dump(ip) when is_binary(ip) do
    case parse_ip(ip) do
      {:ok, tuple} -> {:ok, %Postgrex.INET{address: tuple}}
      :error -> :error
    end
  end

  def dump(%Postgrex.INET{} = inet), do: {:ok, inet}
  def dump(_), do: :error

  # From DB to Elixir — convert Postgrex.INET to string
  def load(%Postgrex.INET{address: addr}) do
    {:ok, format_ip(addr)}
  end

  def load(nil), do: {:ok, nil}
  def load(ip) when is_binary(ip), do: {:ok, ip}
  def load(_), do: :error

  defp parse_ip(ip) when is_binary(ip) do
    ip
    |> String.to_charlist()
    |> :inet.parse_address()
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp format_ip({a, b, c, d, e, f, g, h}) do
    [a, b, c, d, e, f, g, h]
    |> Enum.map_join(":", &Integer.to_string(&1, 16))
  end
end
