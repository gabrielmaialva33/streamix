defmodule Streamix.Iptv.CatalogFacadeTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

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

    test "list_visible_live_channels/2 filters by category across visible providers" do
      user = user_fixture()
      provider = provider_fixture(user, %{name: "Visible Live"})

      category =
        Repo.insert!(%Streamix.Iptv.Category{
          provider_id: provider.id,
          name: "Esportes",
          type: "live",
          external_id: "live-sports"
        })

      matching = channel_fixture(provider, %{name: "Sports Live"})
      other = channel_fixture(provider, %{name: "News Live"})

      Repo.insert_all("item_categories", [
        %{catalog_item_id: matching.catalog_item_id, category_id: category.id}
      ])

      results = Iptv.list_visible_live_channels(user.id, category_id: category.id, limit: 10)

      assert Enum.map(results, & &1.id) == [matching.id]
      refute Enum.any?(results, &(&1.id == other.id))
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

    test "list_movies/2 keeps placeholder adult entries as distinct browse cards" do
      user = user_fixture()
      provider = provider_fixture(user)

      first =
        movie_fixture(provider, %{
          name: "+18 XXX",
          title: "+18 XXX",
          year: nil,
          stream_id: 3_000_001
        })

      second =
        movie_fixture(provider, %{
          name: "+18 XXX",
          title: "+18 XXX",
          year: nil,
          stream_id: 3_000_002
        })

      results =
        Iptv.list_movies(provider.id,
          dedupe: true,
          show_adult: true,
          limit: 10,
          sort: "name_asc"
        )

      assert MapSet.new(results, & &1.id) == MapSet.new([first.id, second.id])

      visible_results =
        Iptv.list_visible_movies(user.id,
          dedupe: true,
          show_adult: true,
          limit: 10,
          sort: "name_asc"
        )

      assert MapSet.new(visible_results, & &1.id) == MapSet.new([first.id, second.id])
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

    test "list_movie_variants/3 does not present unrelated placeholder entries as sources" do
      user = user_fixture()
      provider = provider_fixture(user)

      selected =
        movie_fixture(provider, %{
          name: "+18 XXX",
          title: "+18 XXX",
          year: nil,
          stream_id: 3_100_001
        })

      _unrelated =
        movie_fixture(provider, %{
          name: "+18 XXX",
          title: "+18 XXX",
          year: nil,
          stream_id: 3_100_002
        })

      assert Enum.map(Iptv.list_movie_variants(selected, user.id), & &1.id) == []
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
      assert Enum.all?(results, &Ecto.assoc_loaded?(&1.genres))
      refute Enum.any?(results, &(&1.id == older.id))
    end

    test "search_movies/3 collapses provider variants that disagree on year metadata" do
      user = user_fixture()
      global = global_provider_fixture(%{name: "Global"})
      fallback = provider_fixture(user, %{name: "Fallback", visibility: "public"})

      year_in_title =
        movie_fixture(global, %{
          name: "Evil Island (2023)",
          title: "Evil Island (2023)",
          year: 0,
          stream_id: 1_401
        })

      canonical =
        movie_fixture(fallback, %{
          name: "Evil Island",
          title: "Evil Island",
          year: 2023,
          tmdb_id: "999001",
          stream_id: 1_402
        })

      no_year =
        movie_fixture(fallback, %{
          name: "Evil Island [L]",
          title: nil,
          year: nil,
          stream_id: 1_403
        })

      results = Iptv.search_movies(user.id, "Evil Island", limit: 10)

      assert Enum.map(results, & &1.id) == [canonical.id]
      refute Enum.any?(results, &(&1.id in [year_in_title.id, no_year.id]))
    end

    test "search_movies/3 keeps distinct works with the same title separate" do
      user = user_fixture()
      global = global_provider_fixture(%{name: "Global"})

      remake_original =
        movie_fixture(global, %{
          name: "The Mummy Search",
          title: "The Mummy Search",
          year: 1999,
          stream_id: 1_404
        })

      remake_new =
        movie_fixture(global, %{
          name: "The Mummy Search",
          title: "The Mummy Search",
          year: 2017,
          stream_id: 1_405
        })

      results = Iptv.search_movies(user.id, "Mummy Search", limit: 10)

      assert Enum.sort(Enum.map(results, & &1.id)) ==
               Enum.sort([remake_original.id, remake_new.id])
    end

    test "search_movies/3 fills the page with distinct titles past duplicate variants" do
      user = user_fixture()
      global = global_provider_fixture(%{name: "Global"})
      fallback = provider_fixture(user, %{name: "Fallback", visibility: "public"})

      for {provider, stream_id} <- [{global, 1_406}, {fallback, 1_407}, {fallback, 1_408}] do
        movie_fixture(provider, %{
          name: "Zombie Saga 4K",
          title: "Zombie Saga",
          year: 2020,
          rating: 9.0,
          stream_id: stream_id
        })
      end

      low_rated =
        movie_fixture(global, %{
          name: "Zombie Saga: Origins",
          title: "Zombie Saga: Origins",
          year: 2005,
          rating: 3.0,
          stream_id: 1_409
        })

      results = Iptv.search_movies(user.id, "Zombie Saga", limit: 2)

      assert length(results) == 2
      assert low_rated.id in Enum.map(results, & &1.id)
    end

    test "search_series/3 collapses provider variants that disagree on year metadata" do
      user = user_fixture()
      global = global_provider_fixture(%{name: "Global"})
      fallback = provider_fixture(user, %{name: "Fallback", visibility: "public"})

      _year_in_title =
        series_content_fixture(global, %{
          name: "Dark Absolute (2021)",
          title: "Dark Absolute (2021)",
          year: 0,
          series_id: 1_501
        })

      canonical =
        series_content_fixture(fallback, %{
          name: "Dark Absolute",
          title: "Dark Absolute",
          year: 2021,
          tmdb_id: "999002",
          series_id: 1_502
        })

      _no_year =
        series_content_fixture(fallback, %{
          name: "Dark Absolute [L]",
          title: nil,
          year: nil,
          series_id: 1_503
        })

      results = Iptv.search_series(user.id, "Dark Absolute", limit: 10)

      assert Enum.map(results, & &1.id) == [canonical.id]
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
      next_results = Iptv.list_visible_series(user.id, limit: 5, offset: 5)

      assert length(results) == 5
      assert length(next_results) == 5
      assert MapSet.disjoint?(MapSet.new(results, & &1.id), MapSet.new(next_results, & &1.id))

      assert Enum.map(results, & &1.name) == [
               "AAA Dense Show 4K",
               "ZZZ Unique Show 1",
               "ZZZ Unique Show 10",
               "ZZZ Unique Show 2",
               "ZZZ Unique Show 3"
             ]

      assert Enum.map(next_results, & &1.name) == [
               "ZZZ Unique Show 4",
               "ZZZ Unique Show 5",
               "ZZZ Unique Show 6",
               "ZZZ Unique Show 7",
               "ZZZ Unique Show 8"
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

    test "ranked catalog queries apply offsets in SQL-sized pages" do
      user = user_fixture()
      provider = provider_fixture(user, %{visibility: "public"})
      year = Date.utc_today().year

      [first, second, _third] =
        for {name, rating} <- [{"First", "99.0"}, {"Second", "98.0"}, {"Third", "97.0"}] do
          movie_fixture(provider, %{
            name: name,
            stream_icon: "http://example.com/#{String.downcase(name)}.jpg",
            year: year,
            rating: Decimal.new(rating)
          })
        end

      assert Enum.map(Iptv.list_new_releases(limit: 1, offset: 1), & &1.id) == [second.id]
      assert Enum.map(Iptv.list_top_10_movies(limit: 1, offset: 1), & &1.id) == [second.id]
      assert Enum.map(Iptv.list_trending("movies", limit: 1, offset: 1), & &1.id) == [second.id]
      assert Enum.map(Iptv.list_new_releases(limit: 1), & &1.id) == [first.id]
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
end
