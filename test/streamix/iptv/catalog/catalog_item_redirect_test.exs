defmodule Streamix.Iptv.CatalogItemRedirectTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv.CatalogItemRedirect

  test "a successor replaced in turn keeps the chain intact" do
    :ok = CatalogItemRedirect.record([{1, 2}])
    :ok = CatalogItemRedirect.record([{2, 3}])

    # The 1 -> 2 redirect now points at 3 directly, so deleting item 2 (and
    # any row about it) cannot strand entries that pointed at 1.
    assert Repo.get!(CatalogItemRedirect, 1).successor_id == 3
    assert CatalogItemRedirect.successors([1, 2, 4]) == %{1 => 3, 2 => 3}
  end

  test "a redirect back to an item already replaced does not loop" do
    :ok = CatalogItemRedirect.record([{1, 2}])
    :ok = CatalogItemRedirect.record([{2, 1}])

    assert CatalogItemRedirect.successors([1]) == %{}
    assert CatalogItemRedirect.successors([2]) == %{2 => 1}
  end

  test "ignores self redirects and empty input" do
    assert :ok = CatalogItemRedirect.record([])
    assert :ok = CatalogItemRedirect.record([{5, 5}])
    assert CatalogItemRedirect.successors([5]) == %{}
    assert CatalogItemRedirect.successors([]) == %{}
  end
end
