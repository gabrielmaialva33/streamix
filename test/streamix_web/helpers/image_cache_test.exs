defmodule StreamixWeb.Helpers.ImageCacheTest do
  use ExUnit.Case, async: true
  alias StreamixWeb.Helpers.ImageCache

  setup do
    dir = Path.join(System.tmp_dir!(), "bounded-images-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    server = start_supervised!({ImageCache, name: nil, max_running: 1, max_queued: 0})
    %{server: server, opts: [cache_dir: dir, max_bytes: 6, max_entries: 2, ttl_seconds: 30]}
  end

  test "coalesces misses, bounds simultaneous producers and publishes whole files", %{
    server: server,
    opts: opts
  } do
    parent = self()

    producer = fn ->
      send(parent, {:producing, self()})
      receive do: (:release -> {:ok, "whole"})
    end

    first = Task.async(fn -> ImageCache.fetch("same", producer, opts, server) end)
    assert_receive {:producing, producer_pid}
    second = Task.async(fn -> ImageCache.fetch("same", producer, opts, server) end)

    assert {:error, :cache_busy} =
             ImageCache.fetch("other", fn -> flunk("over capacity") end, opts, server)

    send(producer_pid, :release)
    assert {:ok, "whole", :origin} = Task.await(first)
    assert {:ok, "whole", _} = Task.await(second)

    assert {:ok, "whole", :cache} =
             ImageCache.fetch("same", fn -> flunk("duplicate fetch") end, opts, server)

    refute_receive {:producing, _}

    assert Enum.map(Path.wildcard(Path.join(opts[:cache_dir], "**/*.jpg")), &File.read!/1) == [
             "whole"
           ]

    assert Path.wildcard(Path.join(opts[:cache_dir], "**/*.tmp-*")) == []
  end

  test "evicts to byte/entry budgets and rejects expired entries", %{server: server, opts: opts} do
    for key <- ["a", "b", "c"] do
      assert {:ok, "four", :origin} = ImageCache.fetch(key, fn -> {:ok, "four"} end, opts, server)
    end

    files = Path.wildcard(Path.join(opts[:cache_dir], "**/*.jpg"))
    assert length(files) == 1
    assert Enum.sum(Enum.map(files, &File.stat!(&1).size)) <= 6
    for path <- files, do: File.touch!(path, {{2000, 1, 1}, {0, 0, 0}})
    assert {:ok, "new", :origin} = ImageCache.fetch("c", fn -> {:ok, "new"} end, opts, server)
  end

  test "oversized results are served without spending the disk budget", %{
    server: server,
    opts: opts
  } do
    assert {:ok, "oversized", :origin} =
             ImageCache.fetch("large", fn -> {:ok, "oversized"} end, opts, server)

    assert Path.wildcard(Path.join(opts[:cache_dir], "**/*.jpg")) == []
  end

  test "deadline kills the producer and frees admission", %{server: server, opts: opts} do
    parent = self()

    call =
      Task.async(fn ->
        ImageCache.fetch(
          "blocked",
          fn ->
            send(parent, {:producer, self()})
            receive do: (:never -> {:ok, "x"})
          end,
          opts,
          server
        )
      end)

    assert_receive {:producer, pid}
    monitor = Process.monitor(pid)
    [ref] = :sys.get_state(server).jobs |> Map.keys()
    send(server, {:expire, ref})
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert {:error, :resize_failed} = Task.await(call)
    assert {:ok, "ok", :origin} = ImageCache.fetch("next", fn -> {:ok, "ok"} end, opts, server)
  end

  test "queues distinct cold posters without exceeding producer concurrency", %{opts: opts} do
    server =
      start_supervised!({ImageCache, name: nil, max_running: 1, max_queued: 1},
        id: :queued_images
      )

    parent = self()
    handler = "image-queue-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:streamix, :image_cache, :queued],
      fn _, _, _, pid -> send(pid, :queued) end,
      parent
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    producer = fn ->
      send(parent, {:producer, self()})
      receive do: (:release -> {:ok, "x"})
    end

    first = Task.async(fn -> ImageCache.fetch("first", producer, opts, server) end)
    assert_receive {:producer, first_pid}
    second = Task.async(fn -> ImageCache.fetch("second", producer, opts, server) end)
    assert_receive :queued
    assert {:error, :cache_busy} = ImageCache.fetch("overflow", producer, opts, server)
    refute_receive {:producer, _}
    send(first_pid, :release)
    assert {:ok, "x", :origin} = Task.await(first)
    assert_receive {:producer, second_pid}
    send(second_pid, :release)
    assert {:ok, "x", :origin} = Task.await(second)
  end

  test "a killed cache manager cannot leave its producers running", %{server: server, opts: opts} do
    parent = self()

    call =
      Task.async(fn ->
        try do
          ImageCache.fetch(
            "blocked",
            fn ->
              send(parent, {:producer, self()})
              receive do: (:never -> {:ok, "x"})
            end,
            opts,
            server
          )
        catch
          :exit, _ -> :manager_stopped
        end
      end)

    assert_receive {:producer, pid}
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    monitor = Process.monitor(pid)
    Process.exit(server, :kill)
    assert :manager_stopped = Task.await(call)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
  end
end
