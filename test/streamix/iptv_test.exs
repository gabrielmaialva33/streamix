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
      assert provider.live_channels_count == 0
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
  end

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

  # =============================================================================
  # Categories
  # =============================================================================

  describe "list_categories/1" do
    test "returns unique categories for a provider" do
      user = user_fixture()
      provider = provider_fixture(user)
      # Simulating categories created by sync/fixtures
      # For this test we need to insert categories manually or via fixture
      # Assuming we can insert categories directly for testing
      
      Repo.insert!(%Streamix.Iptv.Category{
        provider_id: provider.id, 
        name: "News", 
        type: "live", 
        external_id: "1"
      })
      Repo.insert!(%Streamix.Iptv.Category{
        provider_id: provider.id, 
        name: "Sports", 
        type: "live", 
        external_id: "2"
      })

      categories = Iptv.list_categories(provider.id)

      names = Enum.map(categories, & &1.name)
      assert "News" in names
      assert "Sports" in names
      assert length(categories) == 2
    end
  end

  # =============================================================================
  # Favorites
  # =============================================================================

  describe "list_favorites/2" do
    test "returns favorites for a user" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)
      favorite_fixture(user, channel)

      favorites = Iptv.list_favorites(user.id)

      assert length(favorites) == 1
      assert hd(favorites).content_id == channel.id
      assert hd(favorites).content_type == "live_channel"
    end

    test "orders by descending inserted_at" do
      user = user_fixture()
      provider = provider_fixture(user)
      ch1 = channel_fixture(provider, %{name: "First"})
      ch2 = channel_fixture(provider, %{name: "Second"})
      favorite_fixture(user, ch1)
      Process.sleep(1000)
      favorite_fixture(user, ch2)

      favorites = Iptv.list_favorites(user.id)

      # Verify ordering is descending by inserted_at
      assert length(favorites) == 2
      [first, second] = favorites
      assert NaiveDateTime.compare(first.inserted_at, second.inserted_at) == :gt
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
  end

  describe "count_favorites_by_type/1" do
    test "returns counts grouped by type" do
      user = user_fixture()
      provider = provider_fixture(user)
      ch = channel_fixture(provider)

      # Add 1 live channel
      favorite_fixture(user, ch)

      # Add 2 movies
      {:ok, _} = Iptv.add_favorite(user.id, "movie", 100, %{content_name: "Movie"})
      {:ok, _} = Iptv.add_favorite(user.id, "movie", 101, %{content_name: "Movie 2"})

      # Add 1 series
      {:ok, _} = Iptv.add_favorite(user.id, "series", 200, %{content_name: "Series"})

      counts = Iptv.count_favorites_by_type(user.id)

      assert counts["live_channel"] == 1
      assert counts["movie"] == 2
      assert counts["series"] == 1
    end
  end

  describe "list_favorite_ids/2" do
    test "returns set of IDs for type" do
      user = user_fixture()
      {:ok, _} = Iptv.add_favorite(user.id, "movie", 100)
      {:ok, _} = Iptv.add_favorite(user.id, "movie", 101)
      {:ok, _} = Iptv.add_favorite(user.id, "series", 200)

      movie_ids = Iptv.list_favorite_ids(user.id, "movie")
      series_ids = Iptv.list_favorite_ids(user.id, "series")

      assert MapSet.member?(movie_ids, 100)
      assert MapSet.member?(movie_ids, 101)
      refute MapSet.member?(movie_ids, 200)
      assert MapSet.member?(series_ids, 200)
    end
  end

  describe "favorite?/3" do
    test "returns true if channel is favorited" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)
      favorite_fixture(user, channel)

      assert Iptv.favorite?(user.id, "live_channel", channel.id)
    end

    test "returns false if channel is not favorited" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)

      refute Iptv.favorite?(user.id, "live_channel", channel.id)
    end
  end

  describe "add_favorite/3" do
    test "adds a favorite" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)

      assert {:ok, %Favorite{}} = Iptv.add_favorite(user.id, "live_channel", channel.id)
      assert Iptv.favorite?(user.id, "live_channel", channel.id)
    end

    test "returns error for duplicate favorite" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)

      {:ok, _} = Iptv.add_favorite(user.id, "live_channel", channel.id)
      assert {:error, changeset} = Iptv.add_favorite(user.id, "live_channel", channel.id)
      assert "has already been taken" in errors_on(changeset).user_id
    end
  end

  describe "remove_favorite/3" do
    test "removes a favorite" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)
      favorite_fixture(user, channel)

      assert {:ok, 1} = Iptv.remove_favorite(user.id, "live_channel", channel.id)
      refute Iptv.favorite?(user.id, "live_channel", channel.id)
    end

    test "returns 0 if favorite doesn't exist" do
      user = user_fixture()
      assert {:ok, 0} = Iptv.remove_favorite(user.id, "live_channel", 0)
    end
  end

  describe "toggle_favorite/3" do
    test "adds favorite if not exists" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)

      assert {:ok, :added} = Iptv.toggle_favorite(user.id, "live_channel", channel.id)
      assert Iptv.favorite?(user.id, "live_channel", channel.id)
    end

    test "removes favorite if exists" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)
      favorite_fixture(user, channel)

      assert {:ok, :removed} = Iptv.toggle_favorite(user.id, "live_channel", channel.id)
      refute Iptv.favorite?(user.id, "live_channel", channel.id)
    end
  end

  # =============================================================================
  # Watch History
  # =============================================================================

  describe "list_watch_history/2" do
    test "returns watch history for a user" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)
      watch_history_fixture(user, channel, 120)

      history = Iptv.list_watch_history(user.id)

      assert length(history) == 1
      assert hd(history).content_id == channel.id
      assert hd(history).content_type == "live_channel"
      assert hd(history).duration_seconds == 120
    end

    test "orders by descending watched_at" do
      user = user_fixture()
      provider = provider_fixture(user)
      ch1 = channel_fixture(provider, %{name: "First"})
      ch2 = channel_fixture(provider, %{name: "Second"})
      watch_history_fixture(user, ch1)
      Process.sleep(1000)
      watch_history_fixture(user, ch2)

      history = Iptv.list_watch_history(user.id)

      # Verify ordering is descending by watched_at
      assert length(history) == 2
      [first, second] = history
      assert DateTime.compare(first.watched_at, second.watched_at) == :gt
    end
  end

  describe "add_watch_history/3" do
    test "adds watch history entry" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)

      assert {:ok, %WatchHistory{} = entry} = Iptv.add_watch_history(user.id, "live_channel", channel.id, %{duration_seconds: 300})
      assert entry.duration_seconds == 300
      assert entry.user_id == user.id
      assert entry.content_id == channel.id
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
  end
end