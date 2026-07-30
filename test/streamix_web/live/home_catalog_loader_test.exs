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

  test "runs independent section loaders concurrently" do
    test_pid = self()
    release_ref = make_ref()

    loader = fn key ->
      fn ->
        send(test_pid, {:loader_started, key, self()})

        receive do
          {:release_loader, ^release_ref} -> key
        end
      end
    end

    task =
      Task.async(fn ->
        HomeCatalogLoader.load(%{
          featured: loader.(:featured),
          stats: loader.(:stats),
          movies: loader.(:movies)
        })
      end)

    loader_pids =
      for expected_key <- [:featured, :stats, :movies], into: %{} do
        assert_receive {:loader_started, ^expected_key, loader_pid}
        {expected_key, loader_pid}
      end

    assert loader_pids |> Map.values() |> Enum.uniq() |> length() == 3
    Enum.each(loader_pids, fn {_key, pid} -> send(pid, {:release_loader, release_ref}) end)

    assert Task.await(task) == %{featured: :featured, stats: :stats, movies: :movies}
  end
end
