defmodule Streamix.Architecture.CatalogBoundaryTest do
  use ExUnit.Case, async: true

  alias Streamix.Catalog

  @web_root Path.expand("../../../lib/streamix_web", __DIR__)

  test "every catalog call made by the web layer is exported by Streamix.Catalog" do
    Code.ensure_loaded!(Catalog)
    calls = remote_calls(@web_root, [:Streamix, :Catalog])

    assert calls != []

    Enum.each(calls, fn {path, line, function, arity} ->
      assert function_exported?(Catalog, function, arity),
             "#{path}:#{line} calls missing Streamix.Catalog.#{function}/#{arity}"
    end)
  end

  test "catalog delivery code no longer calls catalog operations through Streamix.Iptv" do
    catalog_functions =
      Catalog.__info__(:functions)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    violations =
      @web_root
      |> source_files()
      |> Enum.flat_map(fn path ->
        path
        |> remote_calls_in_file([:Iptv])
        |> Enum.filter(fn {_path, _line, function, _arity} ->
          MapSet.member?(catalog_functions, function)
        end)
      end)

    assert violations == [],
           Enum.map_join(violations, "\n", fn {path, line, function, arity} ->
             "#{path}:#{line} calls Iptv.#{function}/#{arity} instead of Streamix.Catalog"
           end)
  end

  defp remote_calls(root, module_parts) do
    root
    |> source_files()
    |> Enum.flat_map(&remote_calls_in_file(&1, module_parts))
  end

  defp remote_calls_in_file(path, module_parts) do
    ast =
      path
      |> File.read!()
      |> Code.string_to_quoted!(file: path, columns: true)

    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {:&, capture_meta,
         [
           {:/, _,
            [
              {{:., _, [{:__aliases__, _, ^module_parts}, function]}, _, []},
              arity
            ]}
         ]} = node,
        acc
        when is_atom(function) and is_integer(arity) ->
          call = {Path.relative_to_cwd(path), capture_meta[:line], function, arity}
          {node, [call | acc]}

        {{:., _, [{:__aliases__, _, ^module_parts}, function]}, call_meta, args} = node, acc
        when is_atom(function) and is_list(args) ->
          call = {Path.relative_to_cwd(path), call_meta[:line], function, length(args)}
          {node, [call | acc]}

        node, acc ->
          {node, acc}
      end)

    calls = calls |> Enum.reverse() |> Enum.uniq()

    Enum.reject(calls, fn {call_path, line, function, arity} ->
      arity == 0 and
        Enum.any?(calls, fn
          {^call_path, ^line, ^function, captured_arity} when captured_arity > 0 -> true
          _other -> false
        end)
    end)
  end

  defp source_files(root) do
    root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
  end
end
