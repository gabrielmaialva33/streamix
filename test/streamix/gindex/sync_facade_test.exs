defmodule Streamix.Gindex.SyncFacadeTest do
  use ExUnit.Case, async: true

  alias Streamix.Gindex

  test "validates a queued path before resolving provider state" do
    assert {:error, :invalid_sync_path} = Gindex.sync_path(%{}, "  ", :movies)
    assert {:error, :invalid_sync_path} = Gindex.sync_path(%{}, nil, :movies)
  end

  test "rejects unknown kinds without creating atoms from external input" do
    assert {:error, {:unsupported_kind, "movies"}} =
             Gindex.sync_path(%{}, "/1:/Movies/", "movies")
  end
end
