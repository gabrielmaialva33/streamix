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

  defp format_overlaps([]), do: "No overlaps."

  defp format_overlaps(overlaps) do
    Enum.map_join(overlaps, "\n", fn {signature, modules} ->
      "  - #{inspect(signature)} owned by #{inspect(Enum.sort(modules))}"
    end)
  end
end
