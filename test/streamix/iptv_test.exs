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

  describe "public catalog summary queries" do
    test "list_movies/2 returns lightweight provider browse cards" do
      user = user_fixture()
      provider = provider_fixture(user)

      movie =
        movie_fixture(provider, %{
          name: "Provider Card",
          stream_icon: "http://example.com/provider-card.jpg",
          plot: "card plot",
          youtube_trailer: "heavy-trailer",
          rating: Decimal.new("8.4"),
          year: 2026
        })

      result =
        provider.id
        |> Iptv.list_movies(limit: 10)
        |> Enum.find(&(&1.id == movie.id))

      assert result
      assert result.name == "Provider Card"
      assert result.stream_icon == "http://example.com/provider-card.jpg"
      assert result.plot == "card plot"
      assert result.youtube_trailer == nil
      assert Ecto.assoc_loaded?(result.genres)
      refute Ecto.assoc_loaded?(result.provider)
      refute Ecto.assoc_loaded?(result.assets)
      refute Ecto.assoc_loaded?(result.credits)
    end

    test "list_movies/2 can collapse provider variants into one browse card" do
      user = user_fixture()
      provider = provider_fixture(user)

      category =
        Repo.insert!(%Streamix.Iptv.Category{
          provider_id: provider.id,
          name: "Terror",
          type: "vod",
          external_id: "vod-terror"
        })

      older =
        movie_fixture(provider, %{
          name: "0.0MHz [L]",
          title: "0.0MHz [L]",
          year: nil,
          stream_id: 2_097_724
        })

      newer =
        movie_fixture(provider, %{
          name: "0.0MHz [L]",
          title: "0.0MHz [L]",
          year: nil,
          stream_id: 2_112_503
        })

      Repo.insert_all("item_categories", [
        %{catalog_item_id: older.catalog_item_id, category_id: category.id},
        %{catalog_item_id: newer.catalog_item_id, category_id: category.id}
      ])

      results =
        Iptv.list_movies(provider.id,
          category_id: category.id,
          dedupe: true,
          limit: 10,
          sort: "name_asc"
        )

      assert Enum.map(results, & &1.id) == [newer.id]
      refute Enum.any?(results, &(&1.id == older.id))
    end

    test "list_movies/2 dedupe ignores punctuation differences in provider titles" do
      user = user_fixture()
      provider = provider_fixture(user)

      older =
        movie_fixture(provider, %{
          name: "#PartiuFama Cancelado no Amor [L]",
          title: "#PartiuFama Cancelado no Amor [L]",
          stream_id: 1_001
        })

      newer =
        movie_fixture(provider, %{
          name: "#PartiuFama: Cancelado no Amor",
          title: "#PartiuFama: Cancelado no Amor",
          stream_id: 1_002
        })

      results = Iptv.list_movies(provider.id, dedupe: true, limit: 10, sort: "name_asc")

      assert Enum.map(results, & &1.id) == [newer.id]
      refute Enum.any?(results, &(&1.id == older.id))
    end

    test "list_movie_variants/3 returns visible provider variants with categories" do
      user = user_fixture()
      provider_a = provider_fixture(user, %{name: "Provider A"})
      provider_b = provider_fixture(user, %{name: "Provider B"})

      category_a =
        Repo.insert!(%Streamix.Iptv.Category{
          provider_id: provider_a.id,
          name: "FILMES I TERROR",
          type: "vod",
          external_id: "vod-terror"
        })

      category_b =
        Repo.insert!(%Streamix.Iptv.Category{
          provider_id: provider_b.id,
          name: "4K HDR",
          type: "vod",
          external_id: "vod-4k-hdr"
        })

      movie_a =
        movie_fixture(provider_a, %{
          name: "0.0MHz [L]",
          title: "0.0MHz [L]",
          stream_id: 2_097_724
        })

      movie_b =
        movie_fixture(provider_b, %{
          name: "0.0MHz 4K HDR",
          title: "0.0MHz 4K HDR",
          year: 2019,
          tmdb_id: "157433",
          stream_id: 2_112_503
        })

      Repo.insert_all("item_categories", [
        %{catalog_item_id: movie_a.catalog_item_id, category_id: category_a.id},
        %{catalog_item_id: movie_b.catalog_item_id, category_id: category_b.id}
      ])

      variants = Iptv.list_movie_variants(movie_b, user.id)

      assert Enum.map(variants, & &1.id) == [movie_b.id, movie_a.id]
      assert Enum.map(variants, & &1.provider.name) == ["Provider B", "Provider A"]

      assert Enum.map(variants, fn movie -> Enum.map(movie.categories, & &1.name) end) == [
               ["4K HDR"],
               ["FILMES I TERROR"]
             ]
    end

    test "list_visible_movies/2 collapses variants across visible providers" do
      user = user_fixture()
      global = global_provider_fixture(%{name: "Global"})
      fallback = provider_fixture(user, %{name: "Fallback", visibility: "public"})

      older =
        movie_fixture(global, %{
          name: "Same Movie",
          title: "Same Movie",
          year: 2026,
          stream_id: 1_101
        })

      newer =
        movie_fixture(fallback, %{
          name: "Same Movie 4K HDR",
          title: "Same Movie 4K HDR",
          year: 2026,
          stream_id: 1_102
        })

      results = Iptv.list_visible_movies(user.id, search: "Same Movie", limit: 10)

      assert Enum.map(results, & &1.id) == [newer.id]
      refute Enum.any?(results, &(&1.id == older.id))
    end

    test "list_visible_movies/2 uses tmdb_id for canonical cards" do
      user = user_fixture()
      global = global_provider_fixture(%{name: "Global"})
      fallback = provider_fixture(user, %{name: "Fallback", visibility: "public"})

      same_title =
        movie_fixture(global, %{
          name: "The Thing",
          title: "The Thing",
          year: 1982,
          tmdb_id: "1091",
          stream_id: 1_301
        })

      remake =
        movie_fixture(fallback, %{
          name: "The Thing",
          title: "The Thing",
          year: 1982,
          tmdb_id: "60935",
          stream_id: 1_302
        })

      localized_variant =
        movie_fixture(fallback, %{
          name: "The Thing 4K HDR",
          title: "A Coisa 4K HDR",
          year: 1982,
          tmdb_id: "1091",
          stream_id: 1_303
        })

      results = Iptv.list_visible_movies(user.id, search: "Thing", limit: 10)
      result_ids = MapSet.new(results, & &1.id)

      assert MapSet.member?(result_ids, localized_variant.id)
      assert MapSet.member?(result_ids, remake.id)
      refute MapSet.member?(result_ids, same_title.id)
    end

    test "list_visible_movies/2 keeps filling the page after dense duplicate variants" do
      user = user_fixture()
      provider = global_provider_fixture(%{name: "Global"})

      for i <- 1..130 do
        movie_fixture(provider, %{
          name: "AAA Dense Movie 4K",
          title: "AAA Dense Movie 4K",
          year: 2026,
          stream_id: 20_000 + i
        })
      end

      for i <- 1..10 do
        movie_fixture(provider, %{
          name: "ZZZ Unique Movie #{i}",
          title: "ZZZ Unique Movie #{i}",
          year: 2026,
          stream_id: 21_000 + i
        })
      end

      results = Iptv.list_visible_movies(user.id, limit: 5)

      assert length(results) == 5

      assert Enum.map(results, & &1.name) == [
               "AAA Dense Movie 4K",
               "ZZZ Unique Movie 1",
               "ZZZ Unique Movie 10",
               "ZZZ Unique Movie 2",
               "ZZZ Unique Movie 3"
             ]
    end

    test "list_series/2 returns lightweight provider browse cards" do
      user = user_fixture()
      provider = provider_fixture(user)

      series =
        series_content_fixture(provider, %{
          name: "Provider Series Card",
          cover: "http://example.com/provider-series.jpg",
          plot: "series card plot",
          youtube_trailer: "heavy-series-trailer",
          rating: Decimal.new("8.7"),
          year: 2026
        })

      result =
        provider.id
        |> Iptv.list_series(limit: 10)
        |> Enum.find(&(&1.id == series.id))

      assert result
      assert result.name == "Provider Series Card"
      assert result.cover == "http://example.com/provider-series.jpg"
      assert result.plot == "series card plot"
      assert result.youtube_trailer == nil
      assert Ecto.assoc_loaded?(result.genres)
      refute Ecto.assoc_loaded?(result.provider)
      refute Ecto.assoc_loaded?(result.assets)
      refute Ecto.assoc_loaded?(result.credits)
    end

    test "list_series/2 can collapse provider variants into one browse card" do
      user = user_fixture()
      provider = provider_fixture(user)

      category =
        Repo.insert!(%Streamix.Iptv.Category{
          provider_id: provider.id,
          name: "Animações",
          type: "series",
          external_id: "series-animation"
        })

      older =
        series_content_fixture(provider, %{
          name: "Disenchantment [L]",
          title: "Disenchantment [L]",
          year: 2018,
          series_id: 1_001
        })

      newer =
        series_content_fixture(provider, %{
          name: "Disenchantment 4K HDR",
          title: "Disenchantment 4K HDR",
          year: 2018,
          series_id: 1_002
        })

      Repo.insert_all("item_categories", [
        %{catalog_item_id: older.catalog_item_id, category_id: category.id},
        %{catalog_item_id: newer.catalog_item_id, category_id: category.id}
      ])

      results =
        Iptv.list_series(provider.id,
          category_id: category.id,
          dedupe: true,
          limit: 10,
          sort: "name_asc"
        )

      assert Enum.map(results, & &1.id) == [newer.id]
      refute Enum.any?(results, &(&1.id == older.id))
    end

    test "list_series/2 search ignores title punctuation" do
      user = user_fixture()
      provider = provider_fixture(user)

      series =
        series_content_fixture(provider, %{
          name: "(Des)encanto",
          title: "(Des)encanto",
          year: 2018,
          series_id: 1_003
        })

      results = Iptv.list_series(provider.id, search: "Desencanto", dedupe: true, limit: 10)

      assert Enum.map(results, & &1.id) == [series.id]
    end

    test "list_visible_series/2 collapses variants across visible providers" do
      user = user_fixture()
      global = global_provider_fixture(%{name: "Global"})
      fallback = provider_fixture(user, %{name: "Fallback", visibility: "public"})

      older =
        series_content_fixture(global, %{
          name: "Same Show",
          title: "Same Show",
          year: 2026,
          series_id: 1_201
        })

      newer =
        series_content_fixture(fallback, %{
          name: "Same Show 4K HDR",
          title: "Same Show 4K HDR",
          year: 2026,
          series_id: 1_202
        })

      results = Iptv.list_visible_series(user.id, search: "Same Show", limit: 10)

      assert Enum.map(results, & &1.id) == [newer.id]
      refute Enum.any?(results, &(&1.id == older.id))
    end

    test "list_visible_series/2 filters by canonical genre" do
      user = user_fixture()
      global = global_provider_fixture(%{name: "Global"})

      drama = Repo.insert!(%Streamix.Iptv.Genre{name: "drama genre test"})

      matching = series_content_fixture(global, %{name: "Dramatic Show", series_id: 1_301})
      other = series_content_fixture(global, %{name: "Comedy Show", series_id: 1_302})

      Repo.insert_all("series_genres", [%{series_id: matching.id, genre_id: drama.id}])

      results = Iptv.list_visible_series(user.id, genre_id: drama.id, limit: 10)

      assert Enum.map(results, & &1.id) == [matching.id]
      refute Enum.any?(results, &(&1.id == other.id))
    end

    test "list_visible_movies/2 filters by canonical genre" do
      user = user_fixture()
      global = global_provider_fixture(%{name: "Global"})

      action = Repo.insert!(%Streamix.Iptv.Genre{name: "action genre test"})

      matching = movie_fixture(global, %{name: "Action Flick", stream_id: 1_303})
      other = movie_fixture(global, %{name: "Quiet Film", stream_id: 1_304})

      Repo.insert_all("movie_genres", [%{movie_id: matching.id, genre_id: action.id}])

      results = Iptv.list_visible_movies(user.id, genre_id: action.id, limit: 10)

      assert Enum.map(results, & &1.id) == [matching.id]
      refute Enum.any?(results, &(&1.id == other.id))
    end

    test "list_genres_for/1 returns genres ordered by content volume" do
      Streamix.Cache.delete("catalog:genres:series")

      global = global_provider_fixture(%{name: "Global"})

      drama = Repo.insert!(%Streamix.Iptv.Genre{name: "volume drama"})
      niche = Repo.insert!(%Streamix.Iptv.Genre{name: "volume niche"})

      series_a = series_content_fixture(global, %{name: "Show A", series_id: 1_305})
      series_b = series_content_fixture(global, %{name: "Show B", series_id: 1_306})

      Repo.insert_all("series_genres", [
        %{series_id: series_a.id, genre_id: drama.id},
        %{series_id: series_b.id, genre_id: drama.id},
        %{series_id: series_a.id, genre_id: niche.id}
      ])

      genres = Iptv.list_genres_for(:series)
      names = Enum.map(genres, & &1.name)

      drama_index = Enum.find_index(names, &(&1 == "volume drama"))
      niche_index = Enum.find_index(names, &(&1 == "volume niche"))

      assert drama_index < niche_index

      Streamix.Cache.delete("catalog:genres:series")
    end

    test "list_visible_series/2 uses tmdb_id for canonical cards" do
      user = user_fixture()
      global = global_provider_fixture(%{name: "Global"})
      fallback = provider_fixture(user, %{name: "Fallback", visibility: "public"})

      original =
        series_content_fixture(global, %{
          name: "The Returned",
          title: "The Returned",
          year: 2012,
          tmdb_id: "43255",
          series_id: 1_401
        })

      same_title =
        series_content_fixture(fallback, %{
          name: "The Returned",
          title: "The Returned",
          year: 2012,
          tmdb_id: "61231",
          series_id: 1_402
        })

      localized_variant =
        series_content_fixture(fallback, %{
          name: "The Returned 4K",
          title: "Les Revenants 4K",
          year: 2012,
          tmdb_id: "43255",
          series_id: 1_403
        })

      results = Iptv.list_visible_series(user.id, search: "Returned", limit: 10)
      result_ids = MapSet.new(results, & &1.id)

      assert MapSet.member?(result_ids, localized_variant.id)
      assert MapSet.member?(result_ids, same_title.id)
      refute MapSet.member?(result_ids, original.id)
    end

    test "list_visible_series/2 keeps filling the page after dense duplicate variants" do
      user = user_fixture()
      provider = global_provider_fixture(%{name: "Global"})

      for i <- 1..130 do
        series_content_fixture(provider, %{
          name: "AAA Dense Show 4K",
          title: "AAA Dense Show 4K",
          year: 2026,
          series_id: 22_000 + i
        })
      end

      for i <- 1..10 do
        series_content_fixture(provider, %{
          name: "ZZZ Unique Show #{i}",
          title: "ZZZ Unique Show #{i}",
          year: 2026,
          series_id: 23_000 + i
        })
      end

      results = Iptv.list_visible_series(user.id, limit: 5)

      assert length(results) == 5

      assert Enum.map(results, & &1.name) == [
               "AAA Dense Show 4K",
               "ZZZ Unique Show 1",
               "ZZZ Unique Show 10",
               "ZZZ Unique Show 2",
               "ZZZ Unique Show 3"
             ]
    end

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
