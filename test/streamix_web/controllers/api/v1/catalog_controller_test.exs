defmodule StreamixWeb.Api.V1.CatalogControllerTest do
  use StreamixWeb.ConnCase, async: false

  import Streamix.IptvFixtures

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

      assert %{"series" => list, "total" => total, "has_more" => has_more} = response
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
      assert response == %{"series" => [], "total" => 0, "has_more" => false}
    end

    test "supports sort=rating_desc without crashing", %{conn: conn, provider: provider} do
      public_series!(provider, %{name: "Low", rating: Decimal.new("5.0")})
      public_series!(provider, %{name: "High", rating: Decimal.new("9.0")})
      public_series!(provider, %{name: "Null rating", rating: nil})

      response =
        conn
        |> get(~p"/api/v1/catalog/series?sort=rating_desc")
        |> json_response(200)

      names = response["series"] |> Enum.map(& &1["name"])
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

      [first, second | _] = response["series"]
      assert first["id"] == newer.id
      assert second["id"] == older.id
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

      names = response["movies"] |> Enum.map(& &1["name"])
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

      [first, second] = response["movies"]
      assert first["id"] == newer.id
      assert second["id"] == older.id
    end

    test "default sort is year desc then name asc", %{conn: conn} do
      response = conn |> get(~p"/api/v1/catalog/movies") |> json_response(200)
      names = response["movies"] |> Enum.map(& &1["name"])
      assert names == ["Newer", "Older"]
    end

    test "unknown sort values fall back to default", %{conn: conn} do
      response =
        conn
        |> get(~p"/api/v1/catalog/movies?sort=bogus_mode")
        |> json_response(200)

      names = response["movies"] |> Enum.map(& &1["name"])
      assert names == ["Newer", "Older"]
    end
  end

  describe "GET /api/v1/catalog/featured" do
    test "returns a featured movie with backdrop list", %{conn: conn, provider: provider} do
      _ = public_movie!(provider, %{name: "Hero Flick", rating: Decimal.new("8.0")})

      response = conn |> get(~p"/api/v1/catalog/featured") |> json_response(200)

      assert %{"featured" => featured, "stats" => stats} = response
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
      assert response["featured"] == nil
      assert is_map(response["stats"])
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

      assert response["type"] == "movie"
      assert is_list(response["items"])
      # Falls back to new-releases when there is no watch history — should still
      # return something.
      assert response["items"] != []
    end

    test "trending?type=series returns series items", %{conn: conn} do
      response =
        conn |> get(~p"/api/v1/catalog/trending?type=series&limit=5") |> json_response(200)

      assert response["type"] == "series"
      assert is_list(response["items"])

      Enum.each(response["items"], fn item ->
        # series summary doesn't include duration
        refute Map.has_key?(item, "duration")
        assert Map.has_key?(item, "poster")
      end)
    end

    test "recent returns movies", %{conn: conn} do
      response = conn |> get(~p"/api/v1/catalog/recent?limit=5") |> json_response(200)
      assert response["type"] == "movie"
      assert is_list(response["items"])
      assert response["items"] != []
    end

    test "top-rated returns movies ordered by rating desc", %{conn: conn} do
      response = conn |> get(~p"/api/v1/catalog/top-rated?limit=5") |> json_response(200)
      assert response["type"] == "movie"
      names = response["items"] |> Enum.map(& &1["name"])
      # "Highly Rated" (9.8) should outrank "New Release" (7.1)
      assert List.first(names) == "Highly Rated"
    end
  end
end
