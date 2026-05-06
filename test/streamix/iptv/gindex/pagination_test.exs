defmodule Streamix.Iptv.Gindex.PaginationTest do
  use ExUnit.Case, async: false

  alias Streamix.Iptv.Gindex.Pagination

  test "module accepts configurable pagination delay" do
    original = Application.get_env(:streamix, Pagination)

    Application.put_env(:streamix, Pagination, delay_ms: 0, jitter_ms: 0)

    on_exit(fn ->
      if original,
        do: Application.put_env(:streamix, Pagination, original),
        else: Application.delete_env(:streamix, Pagination)
    end)

    assert {:module, Pagination} = Code.ensure_compiled(Pagination)
  end
end
