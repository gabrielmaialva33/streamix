defmodule Streamix.IptvTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv
  alias Streamix.Iptv.{Episode, Provider, Season}

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

  describe "create_provider/2" do
    test "creates a provider with valid data" do
      user = user_fixture()

      attrs = %{
        name: "Test Provider",
        url: "http://provider.example.com",
        username: "user",
        password: "pass"
      }

      assert {:ok, %Provider{} = provider} = Iptv.create_provider(user.id, attrs)
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
      user = user_fixture()
      assert {:error, %Ecto.Changeset{}} = Iptv.create_provider(user.id, %{})
    end

    test "validates required fields" do
      user = user_fixture()
      assert {:error, changeset} = Iptv.create_provider(user.id, %{})

      assert "can't be blank" in errors_on(changeset).name
      assert "can't be blank" in errors_on(changeset).url
      assert "can't be blank" in errors_on(changeset).username
      assert "can't be blank" in errors_on(changeset).password
    end

    test "validates URL format" do
      user = user_fixture()

      attrs = valid_provider_attrs(%{url: "not-a-url"})
      assert {:error, changeset} = Iptv.create_provider(user.id, attrs)
      assert "must be a valid HTTP/HTTPS URL" in errors_on(changeset).url
    end

    test "enforces unique constraint on user_id, url, username" do
      user = user_fixture()
      provider = provider_fixture(user)

      duplicate_attrs = %{
        name: "Duplicate",
        url: provider.url,
        username: provider.username,
        password: "different"
      }

      assert {:error, changeset} = Iptv.create_provider(user.id, duplicate_attrs)
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

  describe "public catalog summary queries" do
    test "list_public_movies/1 preloads genres but not credits" do
      user = user_fixture()

      provider =
        provider_fixture(user, %{
          visibility: "public",
          stream_icon: "http://example.com/poster.jpg"
        })

      movie =
        movie_fixture(provider, %{
          name: "Resumo",
          stream_icon: "http://example.com/poster.jpg",
          rating: Decimal.new("999.0"),
          year: 9999
        })

      result =
        Iptv.list_public_movies(limit: 50)
        |> Enum.find(&(&1.id == movie.id))

      assert result
      assert Ecto.assoc_loaded?(result.genres)
      refute Ecto.assoc_loaded?(result.credits)
    end

    test "list_new_releases/1 returns lightweight movie cards" do
      user = user_fixture()

      provider =
        provider_fixture(user, %{
          visibility: "public"
        })

      movie =
        movie_fixture(provider, %{
          name: "Novo Filme",
          stream_icon: "http://example.com/new-release.jpg",
          plot: "plot pesado que nao deve vir para card",
          youtube_trailer: "abc123",
          year: Date.utc_today().year,
          rating: Decimal.new("9.1")
        })

      result =
        Iptv.list_new_releases(limit: 20)
        |> Enum.find(&(&1.id == movie.id))

      assert result
      assert Ecto.assoc_loaded?(result.genres)
      assert result.plot == nil
      assert result.youtube_trailer == nil
    end

    test "list_top_10_series/1 returns lightweight series cards" do
      user = user_fixture()

      provider =
        provider_fixture(user, %{
          visibility: "public"
        })

      series =
        series_content_fixture(provider, %{
          name: "Serie Leve",
          cover: "http://example.com/series-cover.jpg",
          plot: "plot pesado da serie",
          rating: Decimal.new("9.3"),
          year: 2025
        })

      result =
        Iptv.list_top_10_series(limit: 20)
        |> Enum.find(&(&1.id == series.id))

      assert result
      assert Ecto.assoc_loaded?(result.genres)
      assert result.plot == nil
    end

    test "list_public_series/1 preloads genres but not credits" do
      user = user_fixture()

      provider =
        provider_fixture(user, %{
          visibility: "public"
        })

      series =
        series_content_fixture(provider, %{
          name: "Serie Resumo",
          cover: "http://example.com/cover.jpg",
          rating: Decimal.new("999.0"),
          year: 9999
        })

      result =
        Iptv.list_public_series(limit: 50)
        |> Enum.find(&(&1.id == series.id))

      assert result
      assert Ecto.assoc_loaded?(result.genres)
      refute Ecto.assoc_loaded?(result.credits)
    end
  end

  describe "stream lookup queries" do
    test "get_movie_for_stream/1 only preloads provider" do
      user = user_fixture()
      provider = provider_fixture(user)
      movie = movie_fixture(provider, %{stream_icon: "http://example.com/poster.jpg"})

      result = Iptv.get_movie_for_stream(movie.id)

      assert result.id == movie.id
      assert Ecto.assoc_loaded?(result.provider)
      refute Ecto.assoc_loaded?(result.genres)
      refute Ecto.assoc_loaded?(result.credits)
      refute Ecto.assoc_loaded?(result.assets)
    end

    test "get_episode_for_stream/1 loads provider context without unrelated preloads" do
      user = user_fixture()
      provider = provider_fixture(user)
      series = series_content_fixture(provider)

      season =
        %Season{}
        |> Season.changeset(%{
          season_number: 1,
          name: "Season 1",
          series_id: series.id
        })
        |> Repo.insert!()

      episode =
        %Episode{}
        |> Episode.changeset(%{
          episode_id: 101,
          title: "Episode 1",
          episode_num: 1,
          season_id: season.id,
          provider_id: provider.id,
          catalog_item_id: catalog_item_fixture("episode", provider.id).id
        })
        |> Repo.insert!()

      result = Iptv.get_episode_for_stream(episode.id)

      assert result.id == episode.id
      assert Ecto.assoc_loaded?(result.season)
      assert Ecto.assoc_loaded?(result.season.series)
      assert Ecto.assoc_loaded?(result.season.series.provider)
      refute Ecto.assoc_loaded?(result.season.series.assets)
    end
  end

  # =============================================================================
  # Categories
  # =============================================================================

  describe "list_categories/1" do
    test "returns unique categories for a provider" do
      user = user_fixture()
      provider = provider_fixture(user)

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

    test "returns all favorites for user" do
      user = user_fixture()
      provider = provider_fixture(user)
      ch1 = channel_fixture(provider, %{name: "First"})
      ch2 = channel_fixture(provider, %{name: "Second"})
      favorite_fixture(user, ch1)
      favorite_fixture(user, ch2)

      favorites = Iptv.list_favorites(user.id)
      assert length(favorites) == 2

      content_ids = Enum.map(favorites, & &1[:content_id]) |> MapSet.new()
      assert MapSet.member?(content_ids, ch1.id)
      assert MapSet.member?(content_ids, ch2.id)
    end
  end

  describe "list_home_favorites/2" do
    test "returns lightweight favorite cards for home" do
      user = user_fixture()
      provider = provider_fixture(user)

      movie =
        movie_fixture(provider, %{
          name: "Home Favorite",
          stream_icon: "http://example.com/home-favorite.jpg"
        })

      {:ok, _favorite} = Iptv.add_favorite(user.id, "movie", movie.id)

      [favorite] = Iptv.list_home_favorites(user.id, limit: 12)

      assert favorite.content_type == "movie"
      assert favorite.content_id == movie.id
      assert favorite.content_name == "Home Favorite"
      assert favorite.content_icon == "http://example.com/home-favorite.jpg"
      refute Map.has_key?(favorite, :catalog_item)

      assert Map.keys(favorite) |> Enum.sort() == [
               :content_icon,
               :content_id,
               :content_name,
               :content_type,
               :inserted_at
             ]
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
      movie1 = movie_fixture(provider, %{name: "Movie One"})
      movie2 = movie_fixture(provider, %{name: "Movie Two"})
      series = series_content_fixture(provider, %{name: "Series One"})

      # Add 1 live channel
      favorite_fixture(user, ch)

      # Add 2 movies
      {:ok, _} = Iptv.add_favorite(user.id, "movie", movie1.id)
      {:ok, _} = Iptv.add_favorite(user.id, "movie", movie2.id)

      # Add 1 series
      {:ok, _} = Iptv.add_favorite(user.id, "series", series.id)

      counts = Iptv.count_favorites_by_type(user.id)

      assert counts["live_channel"] == 1
      assert counts["movie"] == 2
      assert counts["series"] == 1
    end
  end

  describe "list_favorite_ids/2" do
    test "returns set of IDs for type" do
      user = user_fixture()
      provider = provider_fixture(user)
      movie1 = movie_fixture(provider, %{name: "Movie 100"})
      movie2 = movie_fixture(provider, %{name: "Movie 101"})
      series = series_content_fixture(provider, %{name: "Series 200"})

      {:ok, _} = Iptv.add_favorite(user.id, "movie", movie1.id)
      {:ok, _} = Iptv.add_favorite(user.id, "movie", movie2.id)
      {:ok, _} = Iptv.add_favorite(user.id, "series", series.id)

      movie_ids = Iptv.list_favorite_ids(user.id, "movie")
      series_ids = Iptv.list_favorite_ids(user.id, "series")

      assert MapSet.member?(movie_ids, movie1.id)
      assert MapSet.member?(movie_ids, movie2.id)
      refute MapSet.member?(movie_ids, series.id)
      assert MapSet.member?(series_ids, series.id)
    end
  end

  describe "favorite?/3" do
    test "returns true if channel is favorited" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)
      favorite_fixture(user, channel)

      assert Iptv.is_favorite?(user.id, "live_channel", channel.id)
    end

    test "returns false if channel is not favorited" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)

      refute Iptv.is_favorite?(user.id, "live_channel", channel.id)
    end
  end

  describe "add_favorite/3" do
    test "adds a favorite" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)

      assert {:ok, %{} = fav} = Iptv.add_favorite(user.id, "live_channel", channel.id)

      assert Iptv.is_favorite?(user.id, "live_channel", channel.id)
      assert fav.catalog_item_id == channel.catalog_item_id
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
      refute Iptv.is_favorite?(user.id, "live_channel", channel.id)
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
      assert Iptv.is_favorite?(user.id, "live_channel", channel.id)
    end

    test "removes favorite if exists" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)
      favorite_fixture(user, channel)

      assert {:ok, :removed} = Iptv.toggle_favorite(user.id, "live_channel", channel.id)
      refute Iptv.is_favorite?(user.id, "live_channel", channel.id)
    end
  end

  # =============================================================================
  # Watch History (WatchProgress)
  # =============================================================================

  describe "list_watch_history/2" do
    test "returns watch progress for a user" do
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

    test "returns all watch progress entries for user" do
      user = user_fixture()
      provider = provider_fixture(user)
      ch1 = channel_fixture(provider, %{name: "First"})
      ch2 = channel_fixture(provider, %{name: "Second"})
      watch_history_fixture(user, ch1)
      watch_history_fixture(user, ch2)

      history = Iptv.list_watch_history(user.id)
      assert length(history) == 2

      content_ids = Enum.map(history, & &1[:content_id]) |> MapSet.new()
      assert MapSet.member?(content_ids, ch1.id)
      assert MapSet.member?(content_ids, ch2.id)
    end
  end

  describe "list_home_history/2" do
    test "returns lightweight history cards for home" do
      user = user_fixture()
      provider = provider_fixture(user)

      movie =
        movie_fixture(provider, %{
          name: "History Movie",
          stream_icon: "http://example.com/history-movie.jpg"
        })

      {:ok, _entry} =
        Iptv.add_watch_history(user.id, "movie", movie.id, %{
          progress_seconds: 42,
          duration_seconds: 120
        })

      [entry] = Iptv.list_home_history(user.id, limit: 6)

      assert entry.content_type == "movie"
      assert entry.content_id == movie.id
      assert entry.content_name == "History Movie"
      assert entry.content_icon == "http://example.com/history-movie.jpg"
      assert entry.progress_seconds == 42
      assert entry.duration_seconds == 120
      assert %DateTime{} = entry.watched_at
      refute Map.has_key?(entry, :catalog_item)

      assert Map.keys(entry) |> Enum.sort() == [
               :content_icon,
               :content_id,
               :content_name,
               :content_type,
               :duration_seconds,
               :id,
               :progress_seconds,
               :watched_at
             ]
    end
  end

  describe "add_watch_history/3" do
    test "adds watch progress entry" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)

      assert {:ok, %{} = entry} =
               Iptv.add_watch_history(user.id, "live_channel", channel.id, %{
                 duration_seconds: 300
               })

      assert entry.duration_seconds == 300
      assert entry.user_id == user.id
      assert entry.catalog_item_id == channel.catalog_item_id
    end
  end

  describe "clear_watch_history/1" do
    test "clears all watch progress for user" do
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

  describe "get_series_progress_map/2" do
    test "returns series progress keyed by series id using the latest watched episode" do
      user = user_fixture()
      provider = provider_fixture(user)
      series = series_content_fixture(provider, %{name: "Progress Series"})

      season =
        %Season{}
        |> Season.changeset(%{
          season_number: 1,
          name: "Season 1",
          series_id: series.id
        })
        |> Repo.insert!()

      episode_one =
        %Episode{}
        |> Episode.changeset(%{
          episode_id: 201,
          title: "Episode 1",
          episode_num: 1,
          season_id: season.id,
          catalog_item_id: catalog_item_fixture("episode", provider.id).id
        })
        |> Repo.insert!()

      episode_two =
        %Episode{}
        |> Episode.changeset(%{
          episode_id: 202,
          title: "Episode 2",
          episode_num: 2,
          season_id: season.id,
          catalog_item_id: catalog_item_fixture("episode", provider.id).id
        })
        |> Repo.insert!()

      {:ok, _} =
        Iptv.add_watch_history(user.id, "episode", episode_one.id, %{
          progress_seconds: 30,
          duration_seconds: 120
        })

      {:ok, _} =
        Iptv.add_watch_history(user.id, "episode", episode_two.id, %{
          progress_seconds: 90,
          duration_seconds: 180
        })

      assert Iptv.get_series_progress_map(user.id, [series.id]) == %{series.id => 0.5}
    end
  end
end
