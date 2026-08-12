defmodule Streamix.Gindex.Sync.DiscoveryCursorTest do
  use ExUnit.Case, async: true

  alias Streamix.Gindex.Sync.DiscoveryCursor

  test "preserves a legacy refresh cursor while discovery advances" do
    legacy = %{"root_path" => "/series/", "folder_path" => "/series/B/"}
    discovery = %{"root_path" => "/series/", "folder_path" => "/series/D/"}

    cursor = DiscoveryCursor.load(legacy, ~D[2026-08-11])
    checkpoint = DiscoveryCursor.checkpoint(cursor, :discover, discovery)

    assert checkpoint["phase"] == "discover"
    assert checkpoint["discovery"] == discovery
    assert checkpoint["refresh"] == legacy
  end

  test "starts a fresh discovery pass in a new UTC window without losing refresh progress" do
    checkpoint = %{
      "strategy" => "discovery_first_v1",
      "phase" => "refresh",
      "discovery_window" => "2026-08-10",
      "discovery" => %{},
      "refresh" => %{"root_path" => "/series/", "folder_path" => "/series/C/"}
    }

    cursor = DiscoveryCursor.load(checkpoint, ~D[2026-08-11])

    assert DiscoveryCursor.phase(cursor) == :discover
    assert DiscoveryCursor.position(cursor) == nil

    {_cursor, refresh_checkpoint} = DiscoveryCursor.begin_refresh(cursor)
    assert refresh_checkpoint["refresh"] == checkpoint["refresh"]
  end
end
