defmodule Streamix.Iptv.ChannelsFacadeTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  # =============================================================================
  # Live Channels
  # =============================================================================

  describe "list_live_channels/2" do
    test "returns channels for a provider" do
      user = user_fixture()
      provider = provider_fixture(user)
      channels_fixture(provider, 3)

      channels = Iptv.list_live_channels(provider.id)

      assert length(channels) == 3
    end

    test "returns empty list for provider with no channels" do
      user = user_fixture()
      provider = provider_fixture(user)

      assert Iptv.list_live_channels(provider.id) == []
    end

    test "supports limit option" do
      user = user_fixture()
      provider = provider_fixture(user)
      channels_fixture(provider, 10)

      channels = Iptv.list_live_channels(provider.id, limit: 5)

      assert length(channels) == 5
    end

    test "supports offset option" do
      user = user_fixture()
      provider = provider_fixture(user)
      channels_fixture(provider, 10)

      all = Iptv.list_live_channels(provider.id)
      offset = Iptv.list_live_channels(provider.id, offset: 5)

      assert length(offset) == 5
      refute hd(all).id == hd(offset).id
    end

    test "list_visible_live_channels/2 returns visible providers only" do
      user = user_fixture()
      other_user = user_fixture()
      global = global_provider_fixture(%{name: "Global"})
      public = provider_fixture(user, %{name: "Public", visibility: "public"})
      own_private = provider_fixture(user, %{name: "Own Private"})
      other_private = provider_fixture(other_user, %{name: "Other Private"})

      global_channel = channel_fixture(global, %{name: "Global News"})
      public_channel = channel_fixture(public, %{name: "Public News"})
      private_channel = channel_fixture(own_private, %{name: "Private News"})
      other_channel = channel_fixture(other_private, %{name: "Other News"})

      results = Iptv.list_visible_live_channels(user.id, search: "News", limit: 10)
      result_ids = MapSet.new(results, & &1.id)

      assert MapSet.member?(result_ids, global_channel.id)
      assert MapSet.member?(result_ids, public_channel.id)
      assert MapSet.member?(result_ids, private_channel.id)
      refute MapSet.member?(result_ids, other_channel.id)
    end

    test "supports search filter" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel_fixture(provider, %{name: "BBC News"})
      channel_fixture(provider, %{name: "CNN News"})
      channel_fixture(provider, %{name: "ESPN Sports"})

      channels = Iptv.list_live_channels(provider.id, search: "News")

      assert length(channels) == 2
      assert Enum.all?(channels, &String.contains?(&1.name, "News"))
    end
  end

  describe "count_live_channels/2" do
    test "counts all provider channels when no filter is passed" do
      user = user_fixture()
      provider = provider_fixture(user)
      channels_fixture(provider, 4)

      assert Iptv.count_live_channels(provider.id) == 4
    end

    test "mirrors the search filter from list/2" do
      # Regression: the API's `has_more` would lie on the final page of a
      # filtered result because count ignored search/category filters.
      user = user_fixture()
      provider = provider_fixture(user)
      channel_fixture(provider, %{name: "BBC News"})
      channel_fixture(provider, %{name: "CNN News"})
      channel_fixture(provider, %{name: "ESPN Sports"})

      opts = [search: "News"]

      assert Iptv.count_live_channels(provider.id, opts) ==
               length(Iptv.list_live_channels(provider.id, opts))
    end

    test "returns zero when no channels match the filter" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel_fixture(provider, %{name: "BBC News"})

      assert Iptv.count_live_channels(provider.id, search: "does-not-exist") == 0
    end
  end

  describe "get_live_channel!/1" do
    test "returns the channel with given id" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)

      assert Iptv.get_live_channel!(channel.id).id == channel.id
    end

    test "raises if channel does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Iptv.get_live_channel!(0)
      end
    end
  end
end
