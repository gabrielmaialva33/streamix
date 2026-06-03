defmodule StreamixWeb.HomeCatalogLoaderTest do
  use ExUnit.Case, async: true

  alias StreamixWeb.HomeCatalogLoader

  test "loads section results keyed by name" do
    result =
      HomeCatalogLoader.load(%{
        featured: fn -> {:movie, %{id: 1}} end,
        stats: fn -> %{movies_count: 10} end
      })

    assert result == %{
             featured: {:movie, %{id: 1}},
             stats: %{movies_count: 10}
           }
  end

  # Process.sleep is the natural way to simulate slow fetchers in the
  # three closures below — the assertion is exactly that the loader runs
  # them in parallel (elapsed << 3 * 150ms). No monitored process exists
  # to assert_receive on; the sleep IS the unit under observation.
  test "runs independent section loaders concurrently" do
    started_at = System.monotonic_time(:millisecond)

    result =
      HomeCatalogLoader.load(%{
        featured: fn ->
          Process.sleep(150)
          :featured
        end,
        stats: fn ->
          Process.sleep(150)
          :stats
        end,
        movies: fn ->
          Process.sleep(150)
          :movies
        end
      })

    elapsed = System.monotonic_time(:millisecond) - started_at

    assert result == %{featured: :featured, stats: :stats, movies: :movies}
    assert elapsed < 350
  end
end
