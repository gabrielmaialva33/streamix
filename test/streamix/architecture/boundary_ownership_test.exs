defmodule Streamix.Architecture.BoundaryOwnershipTest do
  use ExUnit.Case, async: true

  @project_root Path.expand("../../..", __DIR__)
  @facade_path Path.join(@project_root, "lib/streamix/iptv.ex")

  @owned_boundaries [
    {Streamix.Catalog, "lib/streamix/catalog.ex", :CatalogBoundary},
    {Streamix.Guide, "lib/streamix/guide.ex", :Guide},
    {Streamix.Library, "lib/streamix/library.ex", :Library},
    {Streamix.Playback, "lib/streamix/playback.ex", :PlaybackBoundary},
    {Streamix.Providers, "lib/streamix/providers.ex", :ProviderBoundary},
    {Streamix.Search, "lib/streamix/search.ex", :Search}
  ]

  @delegate_targets Map.new(@owned_boundaries, fn {module, _path, target} -> {target, module} end)

  test "owned boundaries never call or delegate to the broad compatibility facade" do
    Enum.each(@owned_boundaries, fn {module, relative_path, _target} ->
      path = Path.join(@project_root, relative_path)
      violations = path |> parse_file!() |> facade_dependency_violations()

      assert violations == [], """
      #{inspect(module)} must own its application contract without routing through
      Streamix.Iptv. Nested Streamix.Iptv.* implementation modules are allowed.

      #{format_violations(relative_path, violations)}
      """
    end)
  end

  test "focused boundary contracts do not overlap" do
    ownership =
      Enum.reduce(@owned_boundaries, %{}, fn {module, _path, _target}, acc ->
        Code.ensure_loaded!(module)

        Enum.reduce(module.__info__(:functions), acc, fn signature, signatures ->
          Map.update(signatures, signature, [module], &[module | &1])
        end)
      end)

    overlaps =
      ownership
      |> Enum.filter(fn {_signature, modules} -> length(modules) > 1 end)
      |> Enum.sort()

    assert overlaps == [], """
    Each public function/arity must have one application-boundary owner:

    #{format_overlaps(overlaps)}
    """
  end

  test "Streamix.Iptv preserves every owned-boundary compatibility arity" do
    Code.ensure_loaded!(Streamix.Iptv)

    Enum.each(@owned_boundaries, fn {module, _relative_path, _target} ->
      Code.ensure_loaded!(module)

      missing =
        Enum.reject(module.__info__(:functions), fn {function, arity} ->
          function_exported?(Streamix.Iptv, function, arity)
        end)

      assert missing == [],
             "Streamix.Iptv is missing compatibility delegates for " <>
               "#{inspect(module)}: #{inspect(missing)}"
    end)
  end

  test "the compatibility facade routes every owned arity to its boundary" do
    routed = @facade_path |> parse_file!() |> facade_delegate_routes()

    Enum.each(@owned_boundaries, fn {module, _relative_path, _target} ->
      Code.ensure_loaded!(module)

      expected = MapSet.new(module.__info__(:functions))
      actual = Map.get(routed, module, MapSet.new())
      missing = expected |> MapSet.difference(actual) |> MapSet.to_list() |> Enum.sort()

      assert missing == [], """
      Streamix.Iptv exports compatibility functions for #{inspect(module)}, but these
      arities are not routed through the owning boundary:

      #{inspect(missing, pretty: true)}
      """
    end)
  end

  defp facade_dependency_violations(ast) do
    {_ast, violations} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:alias, meta, [{:__aliases__, _, [:Streamix, :Iptv]} | _options]} = node, acc ->
          {node, MapSet.put(acc, {meta[:line] || 0, :broad_facade_alias})}

        {{:., _, [{:__aliases__, _, module_parts}, function]}, meta, _args} = node, acc
        when module_parts in [[:Iptv], [:Streamix, :Iptv]] and is_atom(function) ->
          if function == :{} do
            {node, acc}
          else
            {node, MapSet.put(acc, {meta[:line] || 0, {:broad_facade_call, function}})}
          end

        {:defdelegate, meta, [_call, options]} = node, acc when is_list(options) ->
          if broad_facade_target?(Keyword.get(options, :to)) do
            {node, MapSet.put(acc, {meta[:line] || 0, :broad_facade_delegate})}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    violations
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp broad_facade_target?({:__aliases__, _, module_parts}),
    do: module_parts in [[:Iptv], [:Streamix, :Iptv]]

  defp broad_facade_target?(_target), do: false

  defp facade_delegate_routes(ast) do
    {_ast, routes} =
      Macro.prewalk(ast, %{}, fn
        {:defdelegate, _meta, [{function, _call_meta, args}, options]} = node, acc
        when is_atom(function) and is_list(args) and is_list(options) ->
          case delegate_boundary(Keyword.get(options, :to)) do
            nil ->
              {node, acc}

            module ->
              signatures = expanded_signatures(function, args)
              {node, Map.update(acc, module, signatures, &MapSet.union(&1, signatures))}
          end

        node, acc ->
          {node, acc}
      end)

    routes
  end

  defp delegate_boundary({:__aliases__, _, [target]}), do: Map.get(@delegate_targets, target)

  defp delegate_boundary({:__aliases__, _, [:Streamix, boundary]}) do
    expected = Module.safe_concat(Streamix, boundary)

    Enum.find_value(@owned_boundaries, fn {module, _path, _target} ->
      if module == expected, do: module
    end)
  end

  defp delegate_boundary(_target), do: nil

  defp expanded_signatures(function, args) do
    maximum = length(args)
    defaults = Enum.count(args, &match?({:\\, _, [_argument, _default]}, &1))
    minimum = maximum - defaults

    minimum..maximum
    |> Enum.map(&{function, &1})
    |> MapSet.new()
  end

  defp parse_file!(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!(file: path, columns: true)
  end

  defp format_violations(_path, []), do: "No violations."

  defp format_violations(path, violations) do
    Enum.map_join(violations, "\n", fn {line, reason} ->
      "  - #{path}:#{line} #{inspect(reason)}"
    end)
  end

  defp format_overlaps([]), do: "No overlaps."

  defp format_overlaps(overlaps) do
    Enum.map_join(overlaps, "\n", fn {signature, modules} ->
      "  - #{inspect(signature)} owned by #{inspect(Enum.sort(modules))}"
    end)
  end
end
