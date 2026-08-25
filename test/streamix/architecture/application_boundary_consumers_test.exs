defmodule Streamix.Architecture.ApplicationBoundaryConsumersTest do
  use ExUnit.Case, async: true

  @project_root Path.expand("../../..", __DIR__)
  @core_root Path.join(@project_root, "lib/streamix")
  @internal_iptv_root Path.join(@core_root, "iptv")

  @boundary_modules [
    Streamix.Catalog,
    Streamix.Guide,
    Streamix.Library,
    Streamix.Playback,
    Streamix.Providers,
    Streamix.Search
  ]

  @excluded_paths MapSet.new([
                    Path.join(@core_root, "iptv.ex"),
                    Path.join(@core_root, "catalog.ex"),
                    Path.join(@core_root, "guide.ex"),
                    Path.join(@core_root, "library.ex"),
                    Path.join(@core_root, "playback.ex"),
                    Path.join(@core_root, "providers.ex"),
                    Path.join(@core_root, "search.ex")
                  ])

  test "production consumers never call the broad Streamix.Iptv facade" do
    violations =
      @core_root
      |> source_files()
      |> Enum.reject(&excluded_path?/1)
      |> Enum.flat_map(fn path ->
        ast = parse_file!(path)
        has_short_alias? = broad_iptv_alias?(ast)

        ast
        |> collect_facade_calls(path, has_short_alias?, [])
        |> Enum.map(fn {call_path, line, function, arity} ->
          {relative_path(call_path), line, function, arity}
        end)
      end)
      |> Enum.uniq()
      |> Enum.sort()

    assert violations == [], """
    Production modules outside the IPTV implementation must depend on focused
    application contexts instead of the historical Streamix.Iptv facade.

    #{format_facade_violations(violations)}
    """
  end

  test "core consumers use focused boundaries for every owned contract" do
    owners = contract_owners()

    violations =
      @core_root
      |> source_files()
      |> Enum.reject(&excluded_path?/1)
      |> Enum.flat_map(&owned_facade_calls(&1, owners))
      |> Enum.uniq()
      |> Enum.sort()

    assert violations == [], """
    Production modules outside the IPTV implementation must call the focused
    owner whenever a function/arity belongs to an application boundary.
    Unowned compatibility operations remain allowed during the migration.

    #{format_violations(violations)}
    """
  end

  defp contract_owners do
    Enum.reduce(@boundary_modules, %{}, fn module, owners ->
      Code.ensure_loaded!(module)

      Enum.reduce(module.__info__(:functions), owners, fn signature, acc ->
        put_owner!(acc, signature, module)
      end)
    end)
  end

  defp put_owner!(owners, signature, module) do
    case Map.fetch(owners, signature) do
      :error ->
        Map.put(owners, signature, module)

      {:ok, existing} ->
        raise "overlapping ownership: #{inspect(signature)} #{inspect(existing)} #{inspect(module)}"
    end
  end

  defp owned_facade_calls(path, owners) do
    ast = parse_file!(path)
    has_short_alias? = broad_iptv_alias?(ast)

    ast
    |> collect_facade_calls(path, has_short_alias?, [])
    |> Enum.flat_map(fn {call_path, line, function, arity} ->
      case Map.get(owners, {function, arity}) do
        nil -> []
        owner -> [{relative_path(call_path), line, owner, function, arity}]
      end
    end)
  end

  defp collect_facade_calls(
         {:|>, pipe_meta,
          [left, {{:., _, [{:__aliases__, _, module_parts}, function]}, call_meta, args}]},
         path,
         has_short_alias?,
         acc
       )
       when is_atom(function) and is_list(args) do
    acc = collect_facade_calls(left, path, has_short_alias?, acc)
    acc = Enum.reduce(args, acc, &collect_facade_calls(&1, path, has_short_alias?, &2))

    if broad_iptv_module?(module_parts, has_short_alias?) do
      line = call_meta[:line] || pipe_meta[:line] || 0
      [{path, line, function, length(args) + 1} | acc]
    else
      acc
    end
  end

  defp collect_facade_calls(
         {:&, capture_meta,
          [{:/, _, [{{:., _, [{:__aliases__, _, module_parts}, function]}, _, []}, arity]}]},
         path,
         has_short_alias?,
         acc
       )
       when is_atom(function) and is_integer(arity) do
    if broad_iptv_module?(module_parts, has_short_alias?) do
      [{path, capture_meta[:line] || 0, function, arity} | acc]
    else
      acc
    end
  end

  defp collect_facade_calls(
         {{:., _, [{:__aliases__, _, module_parts}, function]}, call_meta, args},
         path,
         has_short_alias?,
         acc
       )
       when is_atom(function) and is_list(args) do
    acc = Enum.reduce(args, acc, &collect_facade_calls(&1, path, has_short_alias?, &2))

    if function != :{} and broad_iptv_module?(module_parts, has_short_alias?) do
      [{path, call_meta[:line] || 0, function, length(args)} | acc]
    else
      acc
    end
  end

  defp collect_facade_calls(list, path, has_short_alias?, acc) when is_list(list) do
    Enum.reduce(list, acc, &collect_facade_calls(&1, path, has_short_alias?, &2))
  end

  defp collect_facade_calls(tuple, path, has_short_alias?, acc) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(acc, &collect_facade_calls(&1, path, has_short_alias?, &2))
  end

  defp collect_facade_calls(_node, _path, _has_short_alias?, acc), do: acc

  defp broad_iptv_alias?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:alias, _, [{:__aliases__, _, [:Streamix, :Iptv]} | _options]} = node, _acc ->
          {node, true}

        {:alias, _, [{{:., _, [{:__aliases__, _, [:Streamix]}, :{}]}, _, children}]} = node,
        acc ->
          contains_iptv? = Enum.any?(children, &match?({:__aliases__, _, [:Iptv]}, &1))
          {node, acc or contains_iptv?}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp broad_iptv_module?([:Streamix, :Iptv], _has_short_alias?), do: true
  defp broad_iptv_module?([:Iptv], true), do: true
  defp broad_iptv_module?(_module_parts, _has_short_alias?), do: false

  defp excluded_path?(path) do
    MapSet.member?(@excluded_paths, path) or path_within?(path, @internal_iptv_root)
  end

  defp path_within?(path, root) do
    relative = Path.relative_to(path, root)
    relative != path and relative != ".." and not String.starts_with?(relative, "../")
  end

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

  defp format_facade_violations([]), do: "No violations."

  defp format_facade_violations(violations) do
    Enum.map_join(violations, "\n", fn {path, line, function, arity} ->
      "  - #{path}:#{line} calls Streamix.Iptv.#{function}/#{arity}"
    end)
  end

  defp format_violations([]), do: "No violations."

  defp format_violations(violations) do
    Enum.map_join(violations, "\n", fn {path, line, owner, function, arity} ->
      "  - #{path}:#{line} calls Iptv.#{function}/#{arity}; use #{inspect(owner)}"
    end)
  end
end
