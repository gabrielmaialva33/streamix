defmodule Streamix.Architecture.TestLayoutTest do
  use ExUnit.Case, async: true

  @moduledoc false

  test "direct module tests mirror their source paths" do
    source_paths =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Map.new(fn path -> {top_level_module(path), path} end)

    mismatches =
      "test/**/*_test.exs"
      |> Path.wildcard()
      |> Enum.flat_map(fn test_path ->
        with test_module when is_binary(test_module) <- top_level_module(test_path),
             source_module when is_binary(source_module) <- tested_module(test_module),
             source_path when is_binary(source_path) <- Map.get(source_paths, source_module),
             expected_path = expected_test_path(source_path),
             false <- test_path == expected_path do
          [{test_path, expected_path}]
        else
          _ -> []
        end
      end)
      |> Enum.sort()

    assert mismatches == [],
           """
           Tests named directly after production modules must mirror lib/ under test/.

           #{Enum.map_join(mismatches, "\n", fn {actual, expected} -> "#{actual} -> #{expected}" end)}
           """
  end

  defp top_level_module(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!()
    |> case do
      {:defmodule, _metadata, [{:__aliases__, _alias_metadata, parts}, _body]} ->
        module_name(parts)

      {:__block__, _metadata, forms} ->
        Enum.find_value(forms, &module_name/1)

      _other ->
        nil
    end
  end

  defp module_name({:defmodule, _metadata, [{:__aliases__, _alias_metadata, parts}, _body]}) do
    module_name(parts)
  end

  defp module_name(parts) when is_list(parts) do
    Enum.map_join(parts, ".", &Atom.to_string/1)
  end

  defp module_name(_form), do: nil

  defp tested_module(test_module) do
    if String.ends_with?(test_module, "Test") do
      String.trim_trailing(test_module, "Test")
    end
  end

  defp expected_test_path(source_path) do
    source_path
    |> String.replace_prefix("lib/", "test/")
    |> String.replace_suffix(".ex", "_test.exs")
  end
end
