defmodule Streamix.ArchitectureBoundariesTest do
  use ExUnit.Case, async: true

  @project_root Path.expand("../..", __DIR__)
  @lib_root Path.join(@project_root, "lib")
  @domain_root Path.join(@lib_root, "streamix")
  @web_root Path.join(@lib_root, "streamix_web")
  @composition_roots [Path.join(@domain_root, "application.ex")]
  @iptv_compatibility_facade Path.join(@domain_root, "iptv.ex")

  @library_api_functions [
    :list_favorites,
    :list_home_favorites,
    :favorite?,
    :count_favorites_by_type,
    :list_favorite_ids,
    :count_favorites,
    :add_favorite,
    :remove_favorite,
    :toggle_favorite,
    :list_watch_history,
    :list_home_history,
    :list_watch_history_for_analytics,
    :count_watch_history_by_type,
    :add_watch_history,
    :add_to_watch_history,
    :update_progress,
    :update_watch_progress,
    :update_watch_time,
    :remove_from_watch_history,
    :clear_watch_history,
    :get_watch_progress_map,
    :get_series_progress_map
  ]

  test "the web layer does not call Repo directly" do
    violations =
      @web_root
      |> source_files()
      |> Enum.flat_map(&repo_call_violations/1)

    assert violations == [], """
    StreamixWeb must use application contexts instead of calling Streamix.Repo directly.

    #{format_call_violations(violations)}
    """
  end

  test "domain modules do not depend on StreamixWeb outside composition roots" do
    violations =
      @domain_root
      |> source_files()
      |> Enum.reject(&(&1 in @composition_roots))
      |> Enum.flat_map(&streamix_web_reference_violations/1)

    assert violations == [], """
    Domain modules must not depend on StreamixWeb. Wire web infrastructure only from
    an explicit composition root such as Streamix.Application.

    #{format_web_violations(violations)}
    """
  end

  test "production callers use Library instead of the Iptv compatibility facade" do
    violations =
      @lib_root
      |> source_files()
      |> Enum.reject(&(&1 == @iptv_compatibility_facade))
      |> Enum.flat_map(&iptv_library_call_violations/1)

    assert violations == [], """
    Personal-library operations must use Streamix.Library. Streamix.Iptv keeps these
    delegates only as a compatibility facade and must not gain new internal callers.

    #{format_call_violations(violations)}
    """
  end

  defp source_files(root) do
    root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp repo_call_violations(path) do
    remote_call_violations(path, [:Streamix, :Repo], :all)
  end

  defp iptv_library_call_violations(path) do
    remote_call_violations(path, [:Streamix, :Iptv], @library_api_functions)
  end

  defp remote_call_violations(path, target_module, allowed_functions) do
    ast = parse_file!(path)
    aliases = collect_module_aliases(ast, target_module)

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {{:., _dot_meta, [{:__aliases__, _, module_parts}, function]}, call_meta, args} = node,
        acc
        when is_atom(function) and is_list(args) ->
          if module_reference?(module_parts, target_module, aliases) and
               allowed_function?(function, allowed_functions) do
            violation =
              {relative_path(path), call_meta[:line], Enum.join(target_module, "."), function,
               length(args)}

            {node, [violation | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(violations)
  end

  defp collect_module_aliases(ast, target_module) do
    target_prefix = Enum.drop(target_module, -1)
    target_leaf = List.last(target_module)

    {_ast, aliases} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:alias, _, [{:__aliases__, _, module_parts} | options]} = node, acc
        when module_parts == target_module ->
          {node, MapSet.put(acc, alias_name(options, target_leaf))}

        {:alias, _, [{{:., _, [{:__aliases__, _, prefix_parts}, :{}]}, _, children}]} =
            node,
        acc
        when prefix_parts == target_prefix ->
          aliases =
            if Enum.any?(children, &alias_child?(&1, target_leaf)) do
              MapSet.put(acc, [target_leaf])
            else
              acc
            end

          {node, aliases}

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  defp alias_name([[as: {:__aliases__, _, alias_parts}]], _default), do: alias_parts
  defp alias_name(_options, default), do: [default]

  defp alias_child?({:__aliases__, _, [leaf]}, target_leaf), do: leaf == target_leaf
  defp alias_child?(_child, _target_leaf), do: false

  defp module_reference?(module_parts, target_module, aliases) do
    module_parts == target_module or MapSet.member?(aliases, module_parts)
  end

  defp allowed_function?(_function, :all), do: true
  defp allowed_function?(function, functions), do: function in functions

  defp streamix_web_reference_violations(path) do
    ast = parse_file!(path)

    {_ast, violations} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:__aliases__, meta, [:StreamixWeb | _] = module_parts} = node, acc ->
          violation = {relative_path(path), meta[:line], Enum.join(module_parts, ".")}
          {node, MapSet.put(acc, violation)}

        node, acc ->
          {node, acc}
      end)

    violations
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp parse_file!(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!(file: path, columns: true)
  end

  defp relative_path(path), do: Path.relative_to(path, @project_root)

  defp format_call_violations([]), do: "No violations."

  defp format_call_violations(violations) do
    Enum.map_join(violations, "\n", fn {path, line, module, function, arity} ->
      "  - #{path}:#{line} calls #{inspect(module)}.#{function}/#{arity}"
    end)
  end

  defp format_web_violations([]), do: "No violations."

  defp format_web_violations(violations) do
    Enum.map_join(violations, "\n", fn {path, line, module} ->
      "  - #{path}:#{line} references #{inspect(module)}"
    end)
  end
end
