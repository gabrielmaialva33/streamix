defmodule Streamix.Iptv.Sync.UpstreamGuardTest do
  use Streamix.DataCase, async: true

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv.Movie
  alias Streamix.Iptv.Sync.UpstreamGuard

  test "allows a section whose upstream listed entries" do
    provider = provider_fixture(user_fixture())
    movie_fixture(provider, %{stream_id: 7_001})

    assert UpstreamGuard.ensure_upstream_present([%{"stream_id" => 1}], provider.id,
             schema: Movie
           ) == :ok
  end

  test "allows an empty upstream when the provider has nothing stored yet" do
    provider = provider_fixture(user_fixture())

    assert UpstreamGuard.ensure_upstream_present([], provider.id, schema: Movie) == :ok
  end

  test "refuses an empty upstream when stored rows would be wiped" do
    provider = provider_fixture(user_fixture())
    movie_fixture(provider, %{stream_id: 7_002})

    assert UpstreamGuard.ensure_upstream_present([], provider.id, schema: Movie) ==
             {:error, :empty_upstream_catalog}
  end

  test "scopes the stored-row check to the provider being synced" do
    provider = provider_fixture(user_fixture())
    other = provider_fixture(user_fixture())
    movie_fixture(other, %{stream_id: 7_003})

    # Another provider's rows must not keep this provider from a first sync.
    assert UpstreamGuard.ensure_upstream_present([], provider.id, schema: Movie) == :ok
  end
end
