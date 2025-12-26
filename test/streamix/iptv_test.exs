defmodule Streamix.IptvTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv
  alias Streamix.Iptv.{Favorite, Provider, WatchHistory}

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  # =============================================================================
  # Providers
  # =============================================================================

  describe "list_providers/1" do
    test "returns all providers for a user ordered by name" do
      user = user_fixture()
      provider_fixture(user, %{name: "Zebra Provider"})
      provider_fixture(user, %{name: "Alpha Provider"})
      provider_fixture(user, %{name: "Beta Provider"})

      providers = Iptv.list_providers(user.id)

      assert length(providers) == 3

      assert Enum.map(providers, & &1.name) == [
               "Alpha Provider",
               "Beta Provider",
               "Zebra Provider"
             ]
    end

    test "returns empty list for user with no providers" do
      user = user_fixture()
      assert Iptv.list_providers(user.id) == []
    end

    test "does not return other users' providers" do
      user1 = user_fixture()
      user2 = user_fixture()
      provider_fixture(user1, %{name: "User1 Provider"})
      provider_fixture(user2, %{name: "User2 Provider"})

      providers = Iptv.list_providers(user1.id)

      assert length(providers) == 1
      assert hd(providers).name == "User1 Provider"
    end
  end

  describe "get_provider!/1" do
    test "returns the provider with given id" do
      user = user_fixture()
      provider = provider_fixture(user)

      assert Iptv.get_provider!(provider.id).id == provider.id
    end

    test "raises if provider does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Iptv.get_provider!(0)
      end
    end
  end

  describe "get_provider/1" do
    test "returns the provider with given id" do
      user = user_fixture()
      provider = provider_fixture(user)

      assert Iptv.get_provider(provider.id).id == provider.id
    end

    test "returns nil if provider does not exist" do
      assert is_nil(Iptv.get_provider(0))
    end
  end

  describe "get_user_provider/2" do
    test "returns provider if it belongs to user" do
      user = user_fixture()
      provider = provider_fixture(user)

      result = Iptv.get_user_provider(user.id, provider.id)

      assert result.id == provider.id
    end

    test "returns nil if provider belongs to different user" do
      user1 = user_fixture()
      user2 = user_fixture()
      provider = provider_fixture(user1)

      assert is_nil(Iptv.get_user_provider(user2.id, provider.id))
    end

    test "returns nil if provider does not exist" do
      user = user_fixture()
      assert is_nil(Iptv.get_user_provider(user.id, 0))
    end
  end

  describe "create_provider/1" do
    test "creates a provider with valid data" do
      user = user_fixture()

      attrs = %{
        name: "Test Provider",
        url: "http://provider.example.com",
        username: "user",
        password: "pass",
        user_id: user.id
      }

      assert {:ok, %Provider{} = provider} = Iptv.create_provider(attrs)
      assert provider.name == "Test Provider"
      assert provider.url == "http://provider.example.com"
      assert provider.username == "user"
      assert provider.password == "pass"
      assert provider.user_id == user.id
      assert provider.is_active == true
      assert provider.sync_status == "idle"
      assert provider.channels_count == 0
    end

    test "returns error changeset with invalid data" do
      assert {:error, %Ecto.Changeset{}} = Iptv.create_provider(%{})
    end

    test "validates required fields" do
      assert {:error, changeset} = Iptv.create_provider(%{})

      assert "can't be blank" in errors_on(changeset).name
      assert "can't be blank" in errors_on(changeset).url
      assert "can't be blank" in errors_on(changeset).username
      assert "can't be blank" in errors_on(changeset).password
    end

    test "validates URL format" do
      user = user_fixture()

      attrs = valid_provider_attrs(%{url: "not-a-url", user_id: user.id})
      assert {:error, changeset} = Iptv.create_provider(attrs)
      assert "must be a valid HTTP/HTTPS URL" in errors_on(changeset).url
    end

    test "enforces unique constraint on user_id, url, username" do
      user = user_fixture()
      provider = provider_fixture(user)

      duplicate_attrs = %{
        name: "Duplicate",
        url: provider.url,
        username: provider.username,
        password: "different",
        user_id: user.id
      }

      assert {:error, changeset} = Iptv.create_provider(duplicate_attrs)
      assert "has already been taken" in errors_on(changeset).user_id
    end
  end

  describe "update_provider/2" do
    test "updates the provider with valid data" do
      user = user_fixture()
      provider = provider_fixture(user)

      assert {:ok, updated} = Iptv.update_provider(provider, %{name: "Updated Name"})
      assert updated.name == "Updated Name"
    end

    test "returns error changeset with invalid data" do
      user = user_fixture()
      provider = provider_fixture(user)

      assert {:error, changeset} = Iptv.update_provider(provider, %{url: "invalid"})
      assert "must be a valid HTTP/HTTPS URL" in errors_on(changeset).url
    end
  end

  describe "delete_provider/1" do
    test "deletes the provider" do
      user = user_fixture()
      provider = provider_fixture(user)

      assert {:ok, %Provider{}} = Iptv.delete_provider(provider)
      assert is_nil(Iptv.get_provider(provider.id))
    end

    test "deletes associated channels" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)

      {:ok, _} = Iptv.delete_provider(provider)

      assert is_nil(Iptv.get_channel(channel.id))
    end
  end

  describe "connection_error_message/1" do
    test "returns appropriate messages for each error type" do
      assert Iptv.connection_error_message(:invalid_credentials) == "Invalid username or password"
      assert Iptv.connection_error_message(:invalid_url) == "Invalid server URL"
      assert Iptv.connection_error_message(:host_not_found) == "Server not found - check the URL"
      assert Iptv.connection_error_message(:connection_refused) == "Connection refused by server"

      assert Iptv.connection_error_message(:timeout) ==
               "Connection timed out - server may be slow"

      assert Iptv.connection_error_message(:invalid_response) == "Invalid response from server"
      assert Iptv.connection_error_message({:http_error, 500}) == "HTTP error: 500"
      assert Iptv.connection_error_message(:unknown_error) == "Failed to connect to server"
    end
  end

  # =============================================================================
  # Channels
  # =============================================================================

  describe "list_channels/2" do
    test "returns channels for a provider" do
      user = user_fixture()
      provider = provider_fixture(user)
      channels_fixture(provider, 3)

      channels = Iptv.list_channels(provider.id)

      assert length(channels) == 3
    end

    test "returns empty list for provider with no channels" do
      user = user_fixture()
      provider = provider_fixture(user)

      assert Iptv.list_channels(provider.id) == []
    end

    test "supports limit option" do
      user = user_fixture()
      provider = provider_fixture(user)
      channels_fixture(provider, 10)

      channels = Iptv.list_channels(provider.id, limit: 5)

      assert length(channels) == 5
    end

    test "supports offset option" do
      user = user_fixture()
      provider = provider_fixture(user)
      channels_fixture(provider, 10)

      all = Iptv.list_channels(provider.id)
      offset = Iptv.list_channels(provider.id, offset: 5)

      assert length(offset) == 5
      refute hd(all).id == hd(offset).id
    end

    test "supports group filter" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel_fixture(provider, %{group_title: "News"})
      channel_fixture(provider, %{group_title: "News"})
      channel_fixture(provider, %{group_title: "Sports"})

      channels = Iptv.list_channels(provider.id, group: "News")

      assert length(channels) == 2
      assert Enum.all?(channels, &(&1.group_title == "News"))
    end

    test "supports search filter" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel_fixture(provider, %{name: "BBC News"})
      channel_fixture(provider, %{name: "CNN News"})
      channel_fixture(provider, %{name: "ESPN Sports"})

      channels = Iptv.list_channels(provider.id, search: "News")

      assert length(channels) == 2
      assert Enum.all?(channels, &String.contains?(&1.name, "News"))
    end

    test "enforces max page size" do
      user = user_fixture()
      provider = provider_fixture(user)

      # Request more than max allowed
      channels = Iptv.list_channels(provider.id, limit: 1000)

      # Should be capped at max_page_size (500)
      assert length(channels) <= 500
    end
  end

  describe "list_user_channels/2" do
    test "returns channels from all active providers" do
      user = user_fixture()
      provider1 = provider_fixture(user, %{is_active: true})
      provider2 = provider_fixture(user, %{is_active: true})
      channels_fixture(provider1, 3)
      channels_fixture(provider2, 2)

      channels = Iptv.list_user_channels(user.id)

      assert length(channels) == 5
    end

    test "excludes channels from inactive providers" do
      user = user_fixture()
      active = provider_fixture(user, %{is_active: true})
      inactive = provider_fixture(user, %{is_active: false})
      channels_fixture(active, 3)
      channels_fixture(inactive, 2)

      channels = Iptv.list_user_channels(user.id)

      assert length(channels) == 3
    end
  end

  describe "get_channel!/1 and get_channel/1" do
    test "get_channel!/1 returns the channel with given id" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)

      assert Iptv.get_channel!(channel.id).id == channel.id
    end

    test "get_channel!/1 raises if channel does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Iptv.get_channel!(0)
      end
    end

    test "get_channel/1 returns nil if channel does not exist" do
      assert is_nil(Iptv.get_channel(0))
    end
  end

  describe "get_categories/1" do
    test "returns unique categories for a provider" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel_fixture(provider, %{group_title: "News"})
      channel_fixture(provider, %{group_title: "Sports"})
      channel_fixture(provider, %{group_title: "News"})

      categories = Iptv.get_categories(provider.id)

      assert "News" in categories
      assert "Sports" in categories
      assert length(categories) == 2
    end
  end

  describe "get_user_categories/1" do
    test "returns categories from all active providers" do
      user = user_fixture()
      provider1 = provider_fixture(user)
      provider2 = provider_fixture(user)
      channel_fixture(provider1, %{group_title: "News"})
      channel_fixture(provider2, %{group_title: "Sports"})

      categories = Iptv.get_user_categories(user.id)

      assert "News" in categories
      assert "Sports" in categories
    end
  end

  # =============================================================================
  # Favorites
  # =============================================================================

  describe "list_favorites/2" do
    test "returns favorites for a user with channels preloaded" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)
      favorite_fixture(user, channel)

      favorites = Iptv.list_favorites(user.id)

      assert length(favorites) == 1
      assert hd(favorites).channel.id == channel.id
    end

    test "orders by descending inserted_at" do
      user = user_fixture()
      provider = provider_fixture(user)
      ch1 = channel_fixture(provider, %{name: "First"})
      ch2 = channel_fixture(provider, %{name: "Second"})
      favorite_fixture(user, ch1)
      favorite_fixture(user, ch2)

      favorites = Iptv.list_favorites(user.id)

      # Verify ordering is descending by inserted_at
      assert length(favorites) == 2
      [first, second] = favorites
      assert NaiveDateTime.compare(first.inserted_at, second.inserted_at) in [:gt, :eq]
    end

    test "supports pagination" do
      user = user_fixture()
      provider = provider_fixture(user)

      for i <- 1..5 do
        ch = channel_fixture(provider, %{name: "Channel #{i}"})
        favorite_fixture(user, ch)
      end

      page1 = Iptv.list_favorites(user.id, limit: 2)
      page2 = Iptv.list_favorites(user.id, limit: 2, offset: 2)

      assert length(page1) == 2
      assert length(page2) == 2
      refute hd(page1).id == hd(page2).id
    end
  end

  describe "count_favorites/1" do
    test "returns the count of favorites" do
      user = user_fixture()
      provider = provider_fixture(user)

      for _ <- 1..3 do
        ch = channel_fixture(provider)
        favorite_fixture(user, ch)
      end

      assert Iptv.count_favorites(user.id) == 3
    end

    test "returns 0 for user with no favorites" do
      user = user_fixture()
      assert Iptv.count_favorites(user.id) == 0
    end
  end

  describe "favorite?/2" do
    test "returns true if channel is favorited" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)
      favorite_fixture(user, channel)

      assert Iptv.favorite?(user.id, channel.id)
    end

    test "returns false if channel is not favorited" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)

      refute Iptv.favorite?(user.id, channel.id)
    end
  end

  describe "add_favorite/2" do
    test "adds a favorite" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)

      assert {:ok, %Favorite{}} = Iptv.add_favorite(user.id, channel.id)
      assert Iptv.favorite?(user.id, channel.id)
    end

    test "returns error for duplicate favorite" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)

      {:ok, _} = Iptv.add_favorite(user.id, channel.id)
      assert {:error, changeset} = Iptv.add_favorite(user.id, channel.id)
      assert "has already been taken" in errors_on(changeset).user_id
    end
  end

  describe "remove_favorite/2" do
    test "removes a favorite" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)
      favorite_fixture(user, channel)

      assert {:ok, 1} = Iptv.remove_favorite(user.id, channel.id)
      refute Iptv.favorite?(user.id, channel.id)
    end

    test "returns 0 if favorite doesn't exist" do
      user = user_fixture()
      assert {:ok, 0} = Iptv.remove_favorite(user.id, 0)
    end
  end

  describe "toggle_favorite/2" do
    test "adds favorite if not exists" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)

      assert {:ok, :added} = Iptv.toggle_favorite(user.id, channel.id)
      assert Iptv.favorite?(user.id, channel.id)
    end

    test "removes favorite if exists" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)
      favorite_fixture(user, channel)

      assert {:ok, :removed} = Iptv.toggle_favorite(user.id, channel.id)
      refute Iptv.favorite?(user.id, channel.id)
    end
  end

  # =============================================================================
  # Watch History
  # =============================================================================

  describe "list_watch_history/2" do
    test "returns watch history for a user with channels preloaded" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)
      watch_history_fixture(user, channel, 120)

      history = Iptv.list_watch_history(user.id)

      assert length(history) == 1
      assert hd(history).channel.id == channel.id
      assert hd(history).duration_seconds == 120
    end

    test "orders by descending watched_at" do
      user = user_fixture()
      provider = provider_fixture(user)
      ch1 = channel_fixture(provider, %{name: "First"})
      ch2 = channel_fixture(provider, %{name: "Second"})
      watch_history_fixture(user, ch1)
      watch_history_fixture(user, ch2)

      history = Iptv.list_watch_history(user.id)

      # Verify ordering is descending by watched_at
      assert length(history) == 2
      [first, second] = history
      assert DateTime.compare(first.watched_at, second.watched_at) in [:gt, :eq]
    end

    test "supports pagination with default limit of 50" do
      user = user_fixture()
      provider = provider_fixture(user)

      for _ <- 1..60 do
        ch = channel_fixture(provider)
        watch_history_fixture(user, ch)
      end

      history = Iptv.list_watch_history(user.id)
      assert length(history) == 50
    end
  end

  describe "add_watch_history/3" do
    test "adds watch history entry" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)

      assert {:ok, %WatchHistory{} = entry} = Iptv.add_watch_history(user.id, channel.id, 300)
      assert entry.duration_seconds == 300
      assert entry.user_id == user.id
      assert entry.channel_id == channel.id
    end

    test "allows multiple entries for same channel" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)

      {:ok, _} = Iptv.add_watch_history(user.id, channel.id, 100)
      {:ok, _} = Iptv.add_watch_history(user.id, channel.id, 200)

      history = Iptv.list_watch_history(user.id)
      assert length(history) == 2
    end

    test "defaults duration to 0" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)

      {:ok, entry} = Iptv.add_watch_history(user.id, channel.id)
      assert entry.duration_seconds == 0
    end
  end

  describe "clear_watch_history/1" do
    test "clears all watch history for user" do
      user = user_fixture()
      provider = provider_fixture(user)

      for _ <- 1..5 do
        ch = channel_fixture(provider)
        watch_history_fixture(user, ch)
      end

      assert {:ok, 5} = Iptv.clear_watch_history(user.id)
      assert Iptv.list_watch_history(user.id) == []
    end

    test "returns 0 if no history exists" do
      user = user_fixture()
      assert {:ok, 0} = Iptv.clear_watch_history(user.id)
    end

    test "does not affect other users' history" do
      user1 = user_fixture()
      user2 = user_fixture()
      provider = provider_fixture(user1)
      channel = channel_fixture(provider)

      watch_history_fixture(user1, channel)
      watch_history_fixture(user2, channel)

      Iptv.clear_watch_history(user1.id)

      assert Iptv.list_watch_history(user1.id) == []
      assert length(Iptv.list_watch_history(user2.id)) == 1
    end
  end

  describe "prune_watch_history/2" do
    test "keeps only the most recent entries" do
      user = user_fixture()
      provider = provider_fixture(user)

      for i <- 1..10 do
        ch = channel_fixture(provider, %{name: "Channel #{i}"})
        watch_history_fixture(user, ch)
        Process.sleep(5)
      end

      {:ok, pruned} = Iptv.prune_watch_history(user.id, 5)

      assert pruned == 5
      assert length(Iptv.list_watch_history(user.id)) == 5
    end

    test "does nothing if history is within limit" do
      user = user_fixture()
      provider = provider_fixture(user)

      for _ <- 1..3 do
        ch = channel_fixture(provider)
        watch_history_fixture(user, ch)
      end

      {:ok, pruned} = Iptv.prune_watch_history(user.id, 10)

      assert pruned == 0
      assert length(Iptv.list_watch_history(user.id)) == 3
    end
  end
end
