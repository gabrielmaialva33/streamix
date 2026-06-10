defmodule StreamixWeb.Helpers.Params do
  @moduledoc """
  Shared parsing helpers for user-supplied params (route and query values).
  """

  @doc """
  Parses a positive integer from a param value.

  Accepts integers and binaries; returns `{:ok, integer}` or `:error`.
  """
  @spec parse_positive_integer(term()) :: {:ok, pos_integer()} | :error
  def parse_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  def parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> :error
    end
  end

  def parse_positive_integer(_), do: :error

  @doc """
  Parses an integer from a param value.

  Returns `nil` for `nil`, empty strings, and unparsable binaries.
  Non-binary values pass through unchanged.
  """
  @spec parse_integer(term()) :: term()
  def parse_integer(nil), do: nil
  def parse_integer(""), do: nil

  def parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  def parse_integer(value), do: value
end
