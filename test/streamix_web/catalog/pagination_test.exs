defmodule StreamixWeb.Catalog.PaginationTest do
  use ExUnit.Case, async: true

  alias StreamixWeb.Catalog.Pagination

  test "returns the next usable offset" do
    assert Pagination.metadata(20, 81, 20, 0) == %{
             limit: 20,
             offset: 0,
             total: 81,
             has_more: true,
             next_offset: 20
           }
  end

  test "does not advertise an inaccessible or repeating page" do
    assert Pagination.metadata(1, 100_001, 100, Pagination.max_offset()) == %{
             limit: 100,
             offset: 100_000,
             total: 100_001,
             has_more: false,
             next_offset: nil
           }

    assert Pagination.metadata(0, 100_001, 100, Pagination.max_offset()).has_more == false
  end
end
