defmodule Streamix.Iptv.Streaming.VodMultiplexer.BlockStoreTest do
  # The store is a named singleton started by the application.
  use ExUnit.Case, async: false

  alias Streamix.Iptv.Streaming.VodMultiplexer.BlockStore

  setup do
    previous = Application.get_env(:streamix, :vod_cache_max_bytes)
    BlockStore.reset()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:streamix, :vod_cache_max_bytes, previous),
        else: Application.delete_env(:streamix, :vod_cache_max_bytes)

      BlockStore.reset()
    end)
  end

  # A block written by an earlier boot: on disk, absent from the index.
  defp leave_on_disk(key, data, age_seconds) do
    path = BlockStore.path_for(key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, data)
    File.touch!(path, System.os_time(:second) - age_seconds)
    path
  end

  test "blocks cached before a restart are served again after reindexing" do
    leave_on_disk({"title-a", 0}, "first block", 600)

    assert BlockStore.read({"title-a", 0}) == :miss

    :ok = BlockStore.reindex()

    assert BlockStore.read({"title-a", 0}) == {:ok, "first block"}
    assert BlockStore.size_bytes() == byte_size("first block")
  end

  test "a backlog over budget is trimmed, oldest first" do
    Application.put_env(:streamix, :vod_cache_max_bytes, 25)

    oldest = leave_on_disk({"title-b", 0}, String.duplicate("a", 10), 3_000)
    middle = leave_on_disk({"title-b", 1}, String.duplicate("b", 10), 2_000)
    newest = leave_on_disk({"title-b", 2}, String.duplicate("c", 10), 1_000)

    :ok = BlockStore.reindex()

    refute File.exists?(oldest)
    assert File.exists?(middle)
    assert File.exists?(newest)
    assert BlockStore.size_bytes() == 20
  end

  test "reindexing twice does not count a block twice" do
    leave_on_disk({"title-c", 0}, "block", 60)

    :ok = BlockStore.reindex()
    :ok = BlockStore.reindex()

    assert BlockStore.size_bytes() == byte_size("block")
  end

  test "half-written leftovers are removed and size sidecars kept" do
    partial = leave_on_disk({"title-d", 0}, "half", 600) <> ".partial"
    File.rename!(String.trim_trailing(partial, ".partial"), partial)
    :ok = BlockStore.put_total_size("title-d", 1_000)
    sidecar = BlockStore.total_size_path_for("title-d")

    :ok = BlockStore.reindex()

    refute File.exists?(partial)
    assert File.exists?(sidecar)
    assert BlockStore.size_bytes() == 0
  end
end
