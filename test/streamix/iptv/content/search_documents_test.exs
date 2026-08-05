defmodule Streamix.Iptv.SearchDocumentsTest do
  use Streamix.DataCase, async: true

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv

  test "returns ordered movie projections scoped by provider and cursor" do
    user = user_fixture()
    provider = provider_fixture(user)
    other_provider = provider_fixture(user)

    first = movie_fixture(provider, %{title: "First"})
    second = movie_fixture(provider, %{title: "Second"})
    _other = movie_fixture(other_provider, %{title: "Other"})

    assert [document] =
             Iptv.list_search_documents(:movies, provider.id, after_id: first.id)

    assert document.id == second.id
    assert document.title == "Second"
    assert document.provider_id == provider.id
    assert document.genres == nil
  end

  test "excludes content owned by inactive providers" do
    user = user_fixture()
    provider = provider_fixture(user, %{is_active: false})
    _series = series_content_fixture(provider, %{title: "Hidden"})

    assert Iptv.list_search_documents(:series, provider.id) == []
  end

  test "validates the indexing cursor at the context boundary" do
    assert_raise ArgumentError, fn ->
      Iptv.list_search_documents(:movies, nil, after_id: -1)
    end
  end
end
