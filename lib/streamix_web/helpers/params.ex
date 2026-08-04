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

  @doc "Parses a non-negative integer without accepting partial values."
  @spec parse_non_negative_integer(term()) :: {:ok, non_neg_integer()} | :error
  def parse_non_negative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}

  def parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _ -> :error
    end
  end

  def parse_non_negative_integer(_), do: :error

  @doc "Parses JSON/form boolean values, using the supplied boolean for nil."
  @spec parse_boolean(term(), boolean()) :: {:ok, boolean()} | :error
  def parse_boolean(nil, default) when is_boolean(default), do: {:ok, default}
  def parse_boolean(value, _default) when is_boolean(value), do: {:ok, value}
  def parse_boolean("true", _default), do: {:ok, true}
  def parse_boolean("false", _default), do: {:ok, false}
  def parse_boolean(_value, _default), do: :error

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

  @doc "Parses and clamps an integer param to an inclusive range."
  @spec bounded_integer(term(), integer(), integer(), integer()) :: integer()
  def bounded_integer(value, default, minimum, maximum) do
    parsed = parse_integer(value)
    value = if is_integer(parsed), do: parsed, else: default
    value |> max(minimum) |> min(maximum)
  end

  @doc "Parses and clamps a numeric param to an inclusive range."
  @spec bounded_float(term(), float(), number(), number()) :: float()
  def bounded_float(value, default, minimum, maximum) do
    parsed = parse_float(value)
    value = if is_number(parsed), do: parsed * 1.0, else: default
    value |> max(minimum * 1.0) |> min(maximum * 1.0)
  end

  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value * 1.0

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> float
      _ -> nil
    end
  end

  defp parse_float(_value), do: nil
end
