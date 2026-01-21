defmodule Streamix.Helpers do
  @moduledoc """
  Common helper functions used across the application.
  """

  @doc """
  Escapes special characters in a string for use in SQL LIKE/ILIKE patterns.

  Prevents SQL injection by escaping `%`, `_`, and `\\` characters
  that have special meaning in LIKE patterns.

  ## Examples

      iex> Streamix.Helpers.escape_like("foo%bar")
      "foo\\%bar"

      iex> Streamix.Helpers.escape_like("test_123")
      "test\\_123"

      iex> Streamix.Helpers.escape_like("normal")
      "normal"
  """
  @spec escape_like(String.t()) :: String.t()
  def escape_like(str) when is_binary(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  def escape_like(nil), do: ""
end
