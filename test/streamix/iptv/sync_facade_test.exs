defmodule Streamix.Iptv.SyncFacadeTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  test "rejects a segmented sync for a non-Xtream provider before any upstream request" do
    provider = global_provider_fixture(%{provider_type: :gindex})

    assert {:error, :not_xtream_provider} = Iptv.sync_provider_section(provider, :movies)
  end

  test "rejects an unsupported section before any upstream request" do
    provider = provider_fixture(user_fixture())

    assert {:error, {:unsupported_sync_section, :epg}} =
             Iptv.sync_provider_section(provider, :epg)
  end
end
