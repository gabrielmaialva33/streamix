defmodule Streamix.RuntimeConfig do
  @moduledoc false

  @truthy ~w(1 true yes on)
  @falsy ~w(0 false no off)

  def boolean!(name, value, default) when is_binary(name) and is_boolean(default) do
    case normalize(value) do
      nil ->
        default

      value when value in @truthy ->
        true

      value when value in @falsy ->
        false

      value ->
        raise ArgumentError,
              "#{name} must be a boolean (true/false, yes/no, on/off, or 1/0), got: " <>
                inspect(value)
    end
  end

  def integer!(name, value, default, opts \\ [])
      when is_binary(name) and is_integer(default) do
    integer =
      case normalize(value) do
        nil ->
          default

        value ->
          case Integer.parse(value) do
            {parsed, ""} ->
              parsed

            _other ->
              raise ArgumentError, "#{name} must be an integer, got: #{inspect(value)}"
          end
      end

    validate_integer_bound!(name, integer, :min, Keyword.get(opts, :min))
    validate_integer_bound!(name, integer, :max, Keyword.get(opts, :max))
    integer
  end

  def csv(nil), do: []

  def csv(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize(nil), do: nil

  defp normalize(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp validate_integer_bound!(_name, _integer, _bound, nil), do: :ok

  defp validate_integer_bound!(name, integer, :min, minimum) when integer < minimum do
    raise ArgumentError, "#{name} must be an integer of at least #{minimum}, got: #{integer}"
  end

  defp validate_integer_bound!(name, integer, :max, maximum) when integer > maximum do
    raise ArgumentError, "#{name} must be an integer of at most #{maximum}, got: #{integer}"
  end

  defp validate_integer_bound!(_name, _integer, _bound, _limit), do: :ok
end
