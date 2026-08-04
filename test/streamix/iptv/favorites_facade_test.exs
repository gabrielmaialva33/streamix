defmodule Streamix.Iptv.FavoritesFacadeTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

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

    test "respects the adult-content preference on home cards" do
      user = user_fixture()
      provider = provider_fixture(user)
      regular = movie_fixture(provider, %{name: "Regular Favorite"})
      adult = movie_fixture(provider, %{name: "Adult Favorite"})

      adult_category =
        Repo.insert!(%Streamix.Iptv.Category{
          provider_id: provider.id,
          name: "Adultos",
          type: "vod",
          external_id: "adult-home-favorites",
          is_adult: true
        })

      Repo.insert_all("item_categories", [
        %{catalog_item_id: adult.catalog_item_id, category_id: adult_category.id}
      ])

      {:ok, _favorite} = Iptv.add_favorite(user.id, "movie", regular.id)
      {:ok, _favorite} = Iptv.add_favorite(user.id, "movie", adult.id)

      assert Enum.map(Iptv.list_home_favorites(user.id, show_adult: false), & &1.content_id) == [
               regular.id
             ]

      assert MapSet.new(
               Iptv.list_home_favorites(user.id, show_adult: true),
               & &1.content_id
             ) == MapSet.new([regular.id, adult.id])
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

      assert movie_ids == MapSet.new([movie1.id, movie2.id])
      assert series_ids == MapSet.new([series.id])
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

      assert {:ok, %{} = fav} = Iptv.add_favorite(user.id, "live_channel", channel.id)

      assert Iptv.favorite?(user.id, "live_channel", channel.id)
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
end
