defmodule Streamix.ConfigContractTest do
  use ExUnit.Case, async: true

  test "module-keyed Streamix configuration targets existing modules" do
    missing_modules =
      :streamix
      |> Application.get_all_env()
      |> Keyword.keys()
      |> Enum.filter(&(streamix_module?(&1) and not Code.ensure_loaded?(&1)))

    assert missing_modules == []
  end

  defp streamix_module?(key) when is_atom(key) do
    String.starts_with?(Atom.to_string(key), ["Elixir.Streamix.", "Elixir.StreamixWeb."])
  end

  defp streamix_module?(_key), do: false
end
