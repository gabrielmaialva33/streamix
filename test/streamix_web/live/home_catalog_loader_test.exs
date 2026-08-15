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

    # Waiting on three freshly spawned tasks is exactly the kind of assertion
    # the default 100 ms is too tight for: with the whole suite running at
    # `max_cases: System.schedulers_online()`, the loaders can be queued behind
    # other tests and none of them has even started yet. The timeout is only
    # ever reached when the concurrency is genuinely broken, so a generous one
    # costs nothing on the happy path.
    loader_pids =
      for expected_key <- [:featured, :stats, :movies], into: %{} do
        assert_receive {:loader_started, ^expected_key, loader_pid}, 5_000
        {expected_key, loader_pid}
      end

    assert loader_pids |> Map.values() |> Enum.uniq() |> length() == 3
    Enum.each(loader_pids, fn {_key, pid} -> send(pid, {:release_loader, release_ref}) end)

    assert Task.await(task) == %{featured: :featured, stats: :stats, movies: :movies}
  end
end
