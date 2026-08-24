defmodule Streamix.Architecture.ApplicationBoundariesTest do
  use ExUnit.Case, async: true

  @project_root Path.expand("../../..", __DIR__)
  @web_root Path.join(@project_root, "lib/streamix_web")

  @boundary_modules [
    Streamix.Catalog,
    Streamix.Guide,
    Streamix.Library,
    Streamix.Playback,
    Streamix.Providers,
    Streamix.Search
  ]

  @boundary_aliases %{
    [:Library] => Streamix.Library,
    [:Streamix, :Catalog] => Streamix.Catalog,
    [:Streamix, :Guide] => Streamix.Guide,
    [:Streamix, :Library] => Streamix.Library,
    [:Streamix, :Playback] => Streamix.Playback,
    [:Streamix, :Providers] => Streamix.Providers,
    [:Streamix, :Search] => Streamix.Search
  }

  test "the web layer does not depend on the broad Streamix.Iptv facade" do
    violations =
      @web_root
      |> source_files()
      |> Enum.flat_map(fn path ->
        textual_iptv_references(path) ++ ast_iptv_references(path)
      end)
      |> Enum.uniq()
      |> Enum.sort()

    assert violations == [], """
    StreamixWeb must use the focused application boundaries instead of
    Streamix.Iptv:

    #{format_violations(violations)}
    """
  end

  test "every focused boundary call made by StreamixWeb is exported" do
    calls =
      @web_root
      |> source_files()
      |> Enum.flat_map(&boundary_calls/1)
      |> Enum.uniq()
      |> Enum.sort()

    missing =
      Enum.reject(calls, fn {_path, _line, module, function, arity} ->
        Code.ensure_loaded!(module)
        function_exported?(module, function, arity)
      end)

    assert missing == [], """
    StreamixWeb calls functions missing from their application boundary:

    #{format_missing_calls(missing)}
    """
  end

  test "all focused application boundaries are exercised by the web layer" do
    used =
      @web_root
      |> source_files()
      |> Enum.flat_map(&boundary_calls/1)
      |> Enum.map(&elem(&1, 2))
      |> MapSet.new()

    expected = MapSet.new(@boundary_modules)

    assert used == expected,
           "expected #{inspect(expected)}, got #{inspect(used)}"
  end

  defp boundary_calls(path) do
    path
    |> parse_file!()
    |> collect_boundary_calls(path, [])
    |> Enum.reverse()
  end

  defp collect_boundary_calls({:alias, _meta, _args}, _path, acc), do: acc

  defp collect_boundary_calls(
         {:@, _meta, [{declaration, _declaration_meta, _args}]},
         _path,
         acc
       )
       when declaration in [:type, :typep, :opaque, :spec, :callback, :macrocallback],
       do: acc

  defp collect_boundary_calls(
         {:|>, pipe_meta,
          [left, {{:., _, [{:__aliases__, _, module_parts}, function]}, call_meta, args}]},
         path,
         acc
       )
       when is_atom(function) and is_list(args) do
    acc = collect_boundary_calls(left, path, acc)
    acc = Enum.reduce(args, acc, &collect_boundary_calls(&1, path, &2))

    case boundary_module(module_parts) do
      nil ->
        acc

      module ->
        line = call_meta[:line] || pipe_meta[:line] || 0
        [{relative_path(path), line, module, function, length(args) + 1} | acc]
    end
  end

  defp collect_boundary_calls(
         {:&, capture_meta,
          [
            {:/, _,
             [
               {{:., _, [{:__aliases__, _, module_parts}, function]}, _, []},
               arity
             ]}
          ]},
         path,
         acc
       )
       when is_atom(function) and is_integer(arity) do
    case boundary_module(module_parts) do
      nil -> acc
      module -> [{relative_path(path), capture_meta[:line] || 0, module, function, arity} | acc]
    end
  end

  defp collect_boundary_calls(
         {{:., _, [{:__aliases__, _, module_parts}, function]}, call_meta, args},
         path,
         acc
       )
       when is_atom(function) and is_list(args) do
    acc = Enum.reduce(args, acc, &collect_boundary_calls(&1, path, &2))

    case boundary_module(module_parts) do
      nil ->
        acc

      module ->
        [{relative_path(path), call_meta[:line] || 0, module, function, length(args)} | acc]
    end
  end

  defp collect_boundary_calls(list, path, acc) when is_list(list) do
    Enum.reduce(list, acc, &collect_boundary_calls(&1, path, &2))
  end

  defp collect_boundary_calls(tuple, path, acc) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(acc, &collect_boundary_calls(&1, path, &2))
  end

  defp collect_boundary_calls(_node, _path, acc), do: acc

  defp boundary_module(module_parts), do: Map.get(@boundary_aliases, module_parts)

  defp textual_iptv_references(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      if Regex.match?(~r/\bStreamix\.Iptv\b|\bIptv\.|alias\s+Streamix\.\{[^}]*\bIptv\b/, line) do
        [{relative_path(path), line_number, :textual_iptv_reference}]
      else
        []
      end
    end)
  end

  defp ast_iptv_references(path) do
    ast = parse_file!(path)

    {_ast, references} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:__aliases__, meta, module_parts} = node, acc ->
          if iptv_module?(module_parts) do
            reference = {relative_path(path), meta[:line] || 0, {:iptv_module, module_parts}}
            {node, MapSet.put(acc, reference)}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    MapSet.to_list(references)
  end

  defp iptv_module?([:Iptv | _rest]), do: true
  defp iptv_module?([:Streamix, :Iptv | _rest]), do: true
  defp iptv_module?(_module_parts), do: false

  defp source_files(root) do
    root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp parse_file!(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!(file: path, columns: true)
  end

  defp relative_path(path), do: Path.relative_to(path, @project_root)

  defp format_violations([]), do: "No violations."

  defp format_violations(violations) do
    Enum.map_join(violations, "\n", fn {path, line, reason} ->
      "  - #{path}:#{line} #{inspect(reason)}"
    end)
  end

  defp format_missing_calls([]), do: "No missing calls."

  defp format_missing_calls(missing) do
    Enum.map_join(missing, "\n", fn {path, line, module, function, arity} ->
      "  - #{path}:#{line} calls #{inspect(module)}.#{function}/#{arity}"
    end)
  end
end
