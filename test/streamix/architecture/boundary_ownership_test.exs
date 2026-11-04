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

  test "the broad Streamix.Iptv facade stays retired" do
    refute File.exists?(@facade_path), """
    lib/streamix/iptv.ex was the compatibility facade; it was retired once every caller
    moved to a focused boundary. Add the function to the boundary that owns it instead.
    """

    refute Code.ensure_loaded?(Streamix.Iptv)
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
