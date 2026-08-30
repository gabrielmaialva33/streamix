defmodule Streamix.RuntimeConfig do
  @moduledoc false

  @truthy ~w(1 true yes on)
  @falsy ~w(0 false no off)
  @local_test_database_url "ecto://streamix:streamix@localhost/streamix_test"
  @local_test_redis_url "redis://localhost:6379"

  def load_environment(:dev, system_env, dotenv_loader)
      when is_map(system_env) and is_function(dotenv_loader, 1) do
    dotenv_loader.([".env", system_env])
  end

  def load_environment(_environment, system_env, _dotenv_loader) when is_map(system_env),
    do: system_env

  def local_test_database_url, do: @local_test_database_url
  def local_test_redis_url, do: @local_test_redis_url

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
