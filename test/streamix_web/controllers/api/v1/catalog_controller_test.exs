defmodule StreamixWeb.Api.V1.CatalogControllerTest do
  use StreamixWeb.ConnCase, async: false

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv.{CatalogItem, Category, Episode, Season}
  alias Streamix.Repo

  setup do
    # Keep test runs green regardless of API_KEYS being set in the env.
    # The controllers don't require auth when no keys are configured.
    original_api_keys = Application.get_env(:streamix, :api_keys, [])
    Application.put_env(:streamix, :api_keys, [])
    on_exit(fn -> Application.put_env(:streamix, :api_keys, original_api_keys) end)

    provider = global_provider_fixture()
    {:ok, provider: provider}
  end

  # Convenience: creates a movie with the bits required to survive the
  # featured/trending fallbacks (stream_icon + plot).
  defp public_movie!(provider, attrs) do
    rating = Map.get(attrs, :rating, Decimal.new("8.0"))

    provider
    |> movie_fixture(Map.put(attrs, :rating, rating))
    |> Ecto.Changeset.change(%{
      stream_icon: "https://image.tmdb.org/t/p/w500/#{System.unique_integer([:positive])}.jpg",
      plot: "Some plot."
    })
    |> Repo.update!()
  end

  defp public_series!(provider, attrs) do
    rating = Map.get(attrs, :rating, Decimal.new("8.0"))

    provider
    |> series_content_fixture(Map.put(attrs, :rating, rating))
    |> Ecto.Changeset.change(%{
      cover: "https://image.tmdb.org/t/p/w500/s#{System.unique_integer([:positive])}.jpg"
    })
    |> Repo.update!()
  end

  defp category!(provider, attrs) do
    defaults = %{
      external_id: Integer.to_string(System.unique_integer([:positive])),
      name: "Category #{System.unique_integer([:positive])}",
      type: "vod",
      provider_id: provider.id
    }

    %Category{}
    |> Category.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  # `inserted_at` has 1s precision in Postgres utc_datetime columns. In fast
  # tests two inserts can land in the same second, making created_desc tests
  # flaky. This forces a known gap by rewriting the column directly.
  defp backdate!(record, seconds_ago) do
    ago =
      DateTime.utc_now()
      |> DateTime.add(-seconds_ago, :second)
      |> DateTime.truncate(:second)

    record
    |> Ecto.Changeset.change(%{inserted_at: ago})
    |> Repo.update!()
  end

  describe "GET /api/v1/catalog/series" do
    test "returns 200 with paginated series (regression — used to 500)", %{
      conn: conn,
      provider: provider
    } do
      _s1 = public_series!(provider, %{name: "Alpha", year: 2020})
      _s2 = public_series!(provider, %{name: "Bravo", year: 2021})

      response =
        conn
        |> get(~p"/api/v1/catalog/series?limit=10")
        |> json_response(200)

      assert %{
               "data" => list,
               "meta" => %{
                 "pagination" => %{"total" => total, "has_more" => has_more}
               }
             } = response

      assert is_list(list)
      assert length(list) == 2
      assert total == 2
      assert has_more == false

      # Summary shape — keys the TV app relies on.
      [first | _] = list
      assert Map.has_key?(first, "id")
      assert Map.has_key?(first, "name")
      assert Map.has_key?(first, "title")
      assert Map.has_key?(first, "year")
      assert Map.has_key?(first, "rating")
      assert Map.has_key?(first, "genre")
      assert Map.has_key?(first, "poster")
    end

    test "returns empty list when no provider exists", %{conn: conn, provider: provider} do
      Repo.delete!(provider)

      response = conn |> get(~p"/api/v1/catalog/series") |> json_response(200)
      assert response["data"] == []
      assert response["meta"]["pagination"]["total"] == 0
      assert response["meta"]["pagination"]["has_more"] == false
    end

    test "supports sort=rating_desc without crashing", %{conn: conn, provider: provider} do
      public_series!(provider, %{name: "Low", rating: Decimal.new("5.0")})
      public_series!(provider, %{name: "High", rating: Decimal.new("9.0")})
      public_series!(provider, %{name: "Null rating", rating: nil})

      response =
        conn
        |> get(~p"/api/v1/catalog/series?sort=rating_desc")
        |> json_response(200)

      names = response["data"] |> Enum.map(& &1["name"])
      assert "High" in names
      assert "Low" in names
      # rating_desc with NULLS LAST means non-null ratings come first
      assert Enum.find_index(names, &(&1 == "High")) <
               Enum.find_index(names, &(&1 == "Null rating"))
    end

    test "supports sort=created_desc on series", %{conn: conn, provider: provider} do
      older = provider |> public_series!(%{name: "Older Series"}) |> backdate!(60)
      newer = public_series!(provider, %{name: "Newer Series"})

      response =
        conn
        |> get(~p"/api/v1/catalog/series?sort=created_desc")
        |> json_response(200)

      [first, second | _] = response["data"]
      assert first["id"] == newer.id
      assert second["id"] == older.id
    end

    test "aggregates public providers and supports an exact provider filter", %{
      conn: conn,
      provider: global
    } do
      owner = user_fixture()
      fallback = provider_fixture(owner, %{name: "Fallback", visibility: :public})
      global_series = public_series!(global, %{name: "Global Show"})
      fallback_series = public_series!(fallback, %{name: "Fallback Show"})

      response = conn |> get(~p"/api/v1/catalog/series") |> json_response(200)

      assert response["meta"]["pagination"]["total"] == 2

      assert MapSet.new(response["data"], & &1["id"]) ==
               MapSet.new([global_series.id, fallback_series.id])

      filtered =
        conn
        |> get("/api/v1/catalog/series?provider_id=#{fallback.id}")
        |> json_response(200)

      assert filtered["meta"]["pagination"]["total"] == 1
      assert [%{"id" => id, "provider" => provider}] = filtered["data"]
      assert id == fallback_series.id
      assert provider == %{"id" => fallback.id, "name" => "Fallback", "type" => "xtream"}
    end
  end

  describe "GET /api/v1/catalog/providers" do
    test "exposes only safe public source metadata", %{conn: conn, provider: global} do
      owner = user_fixture()

      fallback =
        provider_fixture(owner, %{
          name: "Fallback",
          visibility: :public,
          movies_count: 12,
          series_count: 4,
          live_channels_count: 2
        })

      private = provider_fixture(owner, %{name: "Private"})

      response = conn |> get(~p"/api/v1/catalog/providers") |> json_response(200)
      ids = MapSet.new(response["data"], & &1["id"])

      assert response["meta"]["total"] == 2
      assert ids == MapSet.new([global.id, fallback.id])
      refute MapSet.member?(ids, private.id)

      fallback_payload = Enum.find(response["data"], &(&1["id"] == fallback.id))

      assert fallback_payload == %{
               "id" => fallback.id,
               "name" => "Fallback",
               "type" => "xtream",
               "content_types" => ["channels", "movies", "series"],
               "catalog_counts" => %{"channels" => 2, "movies" => 12, "series" => 4}
             }

      refute Map.has_key?(fallback_payload, "url")
      refute Map.has_key?(fallback_payload, "username")
      refute Map.has_key?(fallback_payload, "password")
    end
  end

  describe "GET /api/v1/catalog/search" do
    test "normalizes whitespace before applying the minimum query length", %{conn: conn} do
      response =
        conn
        |> get("/api/v1/catalog/search?q=%20%20%20")
        |> json_response(200)

      assert response == %{
               "data" => %{"movies" => [], "series" => [], "channels" => []},
               "meta" => %{
                 "query" => "",
                 "limit_per_type" => 10,
                 "filters" => %{"provider_id" => nil, "provider_type" => nil}
               }
             }
    end

    test "filters every search bucket by provider and provider type", %{
      conn: conn,
      provider: global
    } do
      gindex = global_provider_fixture(%{name: "Drive", provider_type: :gindex})

      _global_movie = public_movie!(global, %{name: "Scoped Search Movie"})
      drive_movie = public_movie!(gindex, %{name: "Scoped Search Movie"})
      drive_series = public_series!(gindex, %{name: "Scoped Search Series"})
      _global_channel = channel_fixture(global, %{name: "Scoped Search Channel"})

      response =
        conn
        |> get(~p"/api/v1/catalog/search?q=Scoped%20Search&provider_type=gindex")
        |> json_response(200)

      assert response["meta"]["filters"] == %{
               "provider_id" => nil,
               "provider_type" => "gindex"
             }

      assert Enum.map(response["data"]["movies"], & &1["id"]) == [drive_movie.id]
      assert Enum.map(response["data"]["series"], & &1["id"]) == [drive_series.id]
      assert response["data"]["channels"] == []

      filtered =
        conn
        |> get("/api/v1/catalog/suggest?q=Scoped&provider_id=#{gindex.id}")
        |> json_response(200)

      assert filtered["meta"]["filters"] == %{
               "provider_id" => gindex.id,
               "provider_type" => nil
             }

      assert Enum.all?(filtered["data"], &(&1["provider"]["id"] == gindex.id))
    end

    test "rejects malformed provider filters", %{conn: conn} do
      response =
        conn
        |> get(~p"/api/v1/catalog/search?q=movie&provider_type=m3u")
        |> json_response(400)

      assert response["error"]["code"] == "invalid_provider_type"
    end
  end

  describe "GET /api/v1/catalog/movies with sort" do
    setup %{provider: provider} do
      older =
        provider
        |> public_movie!(%{name: "Older", year: 2010, rating: Decimal.new("9.5")})
        |> backdate!(60)

      newer = public_movie!(provider, %{name: "Newer", year: 2025, rating: Decimal.new("6.0")})
      {:ok, older: older, newer: newer}
    end

    test "sort=rating_desc orders by rating descending", %{conn: conn} do
      response =
        conn
        |> get(~p"/api/v1/catalog/movies?sort=rating_desc")
        |> json_response(200)

      names = response["data"] |> Enum.map(& &1["name"])
      assert names == ["Older", "Newer"]
    end

    test "sort=created_desc orders by inserted_at desc", %{
      conn: conn,
      older: older,
      newer: newer
    } do
      response =
        conn
        |> get(~p"/api/v1/catalog/movies?sort=created_desc")
        |> json_response(200)

      [first, second] = response["data"]
      assert first["id"] == newer.id
      assert second["id"] == older.id
    end

    test "default sort is year desc then name asc", %{conn: conn} do
      response = conn |> get(~p"/api/v1/catalog/movies") |> json_response(200)
      names = response["data"] |> Enum.map(& &1["name"])
      assert names == ["Newer", "Older"]
    end

    test "rejects unknown sort values against the published contract", %{conn: conn} do
      response =
        conn
        |> get(~p"/api/v1/catalog/movies?sort=bogus_mode")
        |> json_response(400)

      assert response == %{
               "error" => %{
                 "code" => "invalid_parameter",
                 "message" => "Invalid value for parameter sort"
               }
             }
    end
  end

  describe "GET /api/v1/catalog/movies with provider scope" do
    test "aggregates, deduplicates and paginates public sources", %{
      conn: conn,
      provider: global
    } do
      owner = user_fixture()
      fallback = provider_fixture(owner, %{name: "Fallback", visibility: :public})
      private = provider_fixture(owner, %{name: "Private"})

      replaced =
        public_movie!(global, %{
          name: "Shared Movie",
          title: "Shared Movie",
          tmdb_id: "9001",
          year: 2025
        })

      winner =
        public_movie!(fallback, %{
          name: "Shared Movie 4K",
          title: "Shared Movie 4K",
          tmdb_id: "9001",
          year: 2025
        })

      global_only = public_movie!(global, %{name: "Global Only", year: 2024})
      fallback_only = public_movie!(fallback, %{name: "Fallback Only", year: 2023})
      _private = public_movie!(private, %{name: "Never Public", year: 2026})

      response =
        conn
        |> get(~p"/api/v1/catalog/movies?limit=2")
        |> json_response(200)

      assert response["meta"]["pagination"]["total"] == 3
      assert response["meta"]["pagination"]["has_more"] == true
      assert response["meta"]["pagination"]["next_offset"] == 2
      assert length(response["data"]) == 2

      all = conn |> get(~p"/api/v1/catalog/movies?limit=10") |> json_response(200)
      ids = MapSet.new(all["data"], & &1["id"])

      assert ids == MapSet.new([winner.id, global_only.id, fallback_only.id])
      refute MapSet.member?(ids, replaced.id)

      Enum.each(all["data"], fn movie ->
        assert Map.keys(movie["provider"]) |> Enum.sort() == ["id", "name", "type"]
      end)
    end

    test "filters by provider id and provider type without exposing private sources", %{
      conn: conn,
      provider: global
    } do
      owner = user_fixture()
      fallback = provider_fixture(owner, %{name: "Fallback", visibility: :public})
      private = provider_fixture(owner, %{name: "Private"})
      gindex = global_provider_fixture(%{name: "Drive", provider_type: :gindex})

      _global_movie = public_movie!(global, %{name: "Global Movie"})
      fallback_movie = public_movie!(fallback, %{name: "Fallback Movie"})
      _private_movie = public_movie!(private, %{name: "Private Movie"})
      gindex_movie = public_movie!(gindex, %{name: "Drive Movie"})

      fallback_response =
        conn
        |> get("/api/v1/catalog/movies?provider_id=#{fallback.id}")
        |> json_response(200)

      assert fallback_response["meta"]["pagination"]["total"] == 1
      assert [%{"id" => id}] = fallback_response["data"]
      assert id == fallback_movie.id

      gindex_response =
        conn
        |> get(~p"/api/v1/catalog/movies?provider_type=gindex")
        |> json_response(200)

      assert gindex_response["meta"]["pagination"]["total"] == 1
      assert [%{"id" => id, "provider" => %{"type" => "gindex"}}] = gindex_response["data"]
      assert id == gindex_movie.id

      private_response =
        conn
        |> get("/api/v1/catalog/movies?provider_id=#{private.id}")
        |> json_response(200)

      assert private_response["data"] == []
      assert private_response["meta"]["pagination"]["total"] == 0
      assert private_response["meta"]["pagination"]["has_more"] == false
    end

    test "rejects malformed provider filters", %{conn: conn} do
      invalid_id =
        conn
        |> get(~p"/api/v1/catalog/movies?provider_id=12oops")
        |> json_response(400)

      assert invalid_id["error"]["code"] == "invalid_provider_id"

      invalid_type =
        conn
        |> get(~p"/api/v1/catalog/movies?provider_type=m3u")
        |> json_response(400)

      assert invalid_type["error"]["code"] == "invalid_provider_type"
    end
  end

  describe "GET /api/v1/catalog/categories" do
    test "aggregates non-adult categories and preserves their provider identity", %{
      conn: conn,
      provider: global
    } do
      owner = user_fixture()
      fallback = provider_fixture(owner, %{name: "Fallback", visibility: :public})
      global_category = category!(global, %{name: "Global Movies"})
      fallback_category = category!(fallback, %{name: "Fallback Movies"})
      _adult = category!(fallback, %{name: "Adult", is_adult: true})

      response = conn |> get(~p"/api/v1/catalog/categories?type=vod") |> json_response(200)

      assert response["meta"]["total"] == 2

      assert MapSet.new(response["data"], & &1["id"]) ==
               MapSet.new([global_category.id, fallback_category.id])

      assert Enum.find(response["data"], &(&1["id"] == fallback_category.id))["provider"] == %{
               "id" => fallback.id,
               "name" => "Fallback",
               "type" => "xtream"
             }

      filtered =
        conn
        |> get("/api/v1/catalog/categories?type=vod&provider_id=#{fallback.id}")
        |> json_response(200)

      assert Enum.map(filtered["data"], & &1["id"]) == [fallback_category.id]
    end
  end

  describe "GET /api/v1/catalog/featured" do
    test "returns a featured movie with backdrop list", %{conn: conn, provider: provider} do
      _ = public_movie!(provider, %{name: "Hero Flick", rating: Decimal.new("8.0")})

      response = conn |> get(~p"/api/v1/catalog/featured") |> json_response(200)

      assert %{"data" => featured, "meta" => %{"catalog_counts" => stats}} = response
      assert is_map(featured)
      assert featured["type"] == "movie"
      assert featured["id"]
      assert featured["title"]
      # backdrop always a non-empty list when a poster exists.
      assert is_list(featured["backdrop"])
      assert featured["backdrop"] != []
      assert is_map(stats)
    end

    test "returns null featured when no content", %{conn: conn} do
      response = conn |> get(~p"/api/v1/catalog/featured") |> json_response(200)
      assert response["data"] == nil
      assert is_map(response["meta"]["catalog_counts"])
    end

    test "scopes both the hero and catalog counts to one provider", %{conn: conn} do
      gindex = global_provider_fixture(%{name: "Drive", provider_type: :gindex})
      movie = public_movie!(gindex, %{name: "Drive Hero"})

      response =
        conn
        |> get("/api/v1/catalog/featured?provider_id=#{gindex.id}")
        |> json_response(200)

      assert response["data"]["id"] == movie.id
      assert response["data"]["provider"]["id"] == gindex.id

      assert response["meta"] == %{
               "catalog_counts" => %{
                 "channels_count" => 0,
                 "movies_count" => 1,
                 "series_count" => 0
               },
               "filters" => %{"provider_id" => gindex.id, "provider_type" => nil}
             }
    end
  end

  describe "GET /api/v1/catalog/series/:id — hides Season 0 (Specials)" do
    test "detail response skips season 0 but keeps positive seasons", %{
      conn: conn,
      provider: provider
    } do
      series = public_series!(provider, %{name: "Show With Specials", tmdb_id: "tt9"})

      for number <- [0, 1, 2] do
        season =
          %Season{}
          |> Season.changeset(%{
            season_number: number,
            name: "S#{number}",
            series_id: series.id
          })
          |> Repo.insert!()

        ci =
          %CatalogItem{}
          |> CatalogItem.changeset(%{content_type: "episode", provider_id: provider.id})
          |> Repo.insert!()

        %Episode{}
        |> Episode.changeset(%{
          episode_id: System.unique_integer([:positive]),
          episode_num: 1,
          title: "S#{number}E1",
          season_id: season.id,
          catalog_item_id: ci.id
        })
        |> Repo.insert!()
      end

      response =
        conn
        |> get(~p"/api/v1/catalog/series/#{series.id}")
        |> json_response(200)

      detail = response["data"]
      season_numbers = detail["seasons"] |> Enum.map(& &1["season_number"])
      assert 0 not in season_numbers
      assert Enum.sort(season_numbers) == [1, 2]
      assert detail["season_count"] == 2
    end
  end

  describe "public catalog detail access" do
    test "rejects malformed ids before querying the catalog", %{conn: conn} do
      response =
        conn
        |> get(~p"/api/v1/catalog/movies/not-a-number")
        |> json_response(400)

      assert response == %{
               "error" => %{
                 "code" => "invalid_parameter",
                 "message" => "Invalid value for parameter id"
               }
             }
    end

    test "does not expose a private series by direct id", %{conn: conn} do
      owner = user_fixture()
      provider = provider_fixture(owner)
      series = series_content_fixture(provider, %{name: "Private Show"})

      response =
        conn
        |> get(~p"/api/v1/catalog/series/#{series.id}")
        |> json_response(404)

      assert response == %{
               "error" => %{
                 "code" => "content_not_found",
                 "message" => "Series not found"
               }
             }
    end
  end

  describe "public catalog stream access" do
    test "does not issue stream URLs for private provider content", %{conn: conn} do
      owner = user_fixture()
      provider = provider_fixture(owner)
      movie = movie_fixture(provider)
      channel = channel_fixture(provider)
      episode = private_episode_fixture(provider)

      assert conn
             |> get(~p"/api/v1/catalog/movies/#{movie.id}/stream")
             |> json_response(404) ==
               %{
                 "error" => %{
                   "code" => "content_not_found",
                   "message" => "Movie not found"
                 }
               }

      assert conn
             |> get(~p"/api/v1/catalog/channels/#{channel.id}/stream")
             |> json_response(404) ==
               %{
                 "error" => %{
                   "code" => "content_not_found",
                   "message" => "Channel not found"
                 }
               }

      assert conn
             |> get(~p"/api/v1/catalog/episodes/#{episode.id}/stream")
             |> json_response(404) ==
               %{
                 "error" => %{
                   "code" => "content_not_found",
                   "message" => "Episode not found"
                 }
               }
    end
  end

  describe "GET /api/v1/catalog/channels — has_more honors dead-channel filter" do
    test "has_more is false on last page when remainder is dead", %{
      conn: conn,
      provider: provider
    } do
      # 2 healthy channels, 1 dead. list() returns 2, count() must also 2 —
      # otherwise has_more would stay true forever.
      now = DateTime.utc_now(:second)

      _alive_a = channel_fixture(provider, %{name: "Alive A"})
      _alive_b = channel_fixture(provider, %{name: "Alive B"})

      dead = channel_fixture(provider, %{name: "Dead Gone"})

      dead
      |> Ecto.Changeset.change(%{dead_since: now})
      |> Repo.update!()

      response =
        conn
        |> get(~p"/api/v1/catalog/channels?limit=50")
        |> json_response(200)

      assert response["meta"]["pagination"]["total"] == 2
      assert length(response["data"]) == 2
      assert response["meta"]["pagination"]["has_more"] == false

      names = response["data"] |> Enum.map(& &1["name"])
      refute "Dead Gone" in names
    end

    test "aggregates channels from public Xtream providers and filters by source", %{
      conn: conn,
      provider: global
    } do
      owner = user_fixture()
      fallback = provider_fixture(owner, %{name: "Fallback", visibility: :public})
      global_channel = channel_fixture(global, %{name: "Global News"})
      fallback_channel = channel_fixture(fallback, %{name: "Fallback News"})

      response = conn |> get(~p"/api/v1/catalog/channels") |> json_response(200)

      assert response["meta"]["pagination"]["total"] == 2

      assert MapSet.new(response["data"], & &1["id"]) ==
               MapSet.new([global_channel.id, fallback_channel.id])

      filtered =
        conn
        |> get("/api/v1/catalog/channels?provider_id=#{fallback.id}")
        |> json_response(200)

      assert filtered["meta"]["pagination"]["total"] == 1

      assert [%{"id" => id, "provider" => %{"id" => provider_id, "type" => "xtream"}}] =
               filtered["data"]

      assert id == fallback_channel.id
      assert provider_id == fallback.id
    end
  end

  describe "GET /api/v1/catalog/trending|recent|top-rated" do
    setup %{provider: provider} do
      public_movie!(provider, %{name: "Highly Rated", year: 2023, rating: Decimal.new("9.8")})
      public_movie!(provider, %{name: "New Release", year: 2025, rating: Decimal.new("7.1")})
      public_series!(provider, %{name: "Top Series", year: 2024, rating: Decimal.new("9.1")})
      :ok
    end

    test "trending defaults to type=movie and returns items", %{conn: conn} do
      response = conn |> get(~p"/api/v1/catalog/trending?limit=5") |> json_response(200)

      assert response["meta"]["type"] == "movie"
      assert is_list(response["data"])
      # Falls back to new-releases when there is no watch history — should still
      # return something.
      assert response["data"] != []
    end

    test "trending?type=series returns series items", %{conn: conn} do
      response =
        conn |> get(~p"/api/v1/catalog/trending?type=series&limit=5") |> json_response(200)

      assert response["meta"]["type"] == "series"
      assert is_list(response["data"])

      Enum.each(response["data"], fn item ->
        # series summary doesn't include duration
        refute Map.has_key?(item, "duration")
        assert Map.has_key?(item, "poster")
      end)
    end

    test "recent returns movies", %{conn: conn} do
      response = conn |> get(~p"/api/v1/catalog/recent?limit=5") |> json_response(200)
      assert response["meta"]["type"] == "movie"
      assert is_list(response["data"])
      assert response["data"] != []
    end

    test "top-rated returns movies ordered by rating desc", %{conn: conn} do
      response = conn |> get(~p"/api/v1/catalog/top-rated?limit=5") |> json_response(200)
      assert response["meta"]["type"] == "movie"
      names = response["data"] |> Enum.map(& &1["name"])
      # "Highly Rated" (9.8) should outrank "New Release" (7.1)
      assert List.first(names) == "Highly Rated"
    end

    test "filters curated shelves by provider", %{conn: conn} do
      gindex = global_provider_fixture(%{name: "Drive", provider_type: :gindex})
      drive = public_movie!(gindex, %{name: "Drive Top", rating: Decimal.new("9.9")})

      response =
        conn
        |> get("/api/v1/catalog/top-rated?provider_id=#{gindex.id}&limit=5")
        |> json_response(200)

      assert Enum.map(response["data"], & &1["id"]) == [drive.id]

      assert response["meta"]["filters"] == %{
               "provider_id" => gindex.id,
               "provider_type" => nil
             }
    end
  end

  defp private_episode_fixture(provider) do
    series = series_content_fixture(provider, %{name: "Private Series"})

    season =
      %Season{}
      |> Season.changeset(%{season_number: 1, name: "Season 1", series_id: series.id})
      |> Repo.insert!()

    catalog_item =
      %CatalogItem{}
      |> CatalogItem.changeset(%{content_type: "episode", provider_id: provider.id})
      |> Repo.insert!()

    %Episode{}
    |> Episode.changeset(%{
      episode_id: System.unique_integer([:positive]),
      episode_num: 1,
      title: "Private Episode",
      season_id: season.id,
      catalog_item_id: catalog_item.id
    })
    |> Repo.insert!()
  end
end
