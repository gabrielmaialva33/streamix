defmodule StreamixWeb.Content.DetailPremiumSignalsTest do
  use StreamixWeb.ConnCase

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  alias Streamix.Billing.{Plan, Subscription}
  import Streamix.IptvFixtures

  alias Streamix.Iptv.{Season, Series}
  alias Streamix.Repo

  defp series_fixture(provider, attrs) do
    params =
      Enum.into(attrs, %{
        series_id: System.unique_integer([:positive]),
        name: "Series #{System.unique_integer([:positive])}",
        title: "Series Title #{System.unique_integer([:positive])}",
        year: 2024,
        provider_id: provider.id,
        episode_count: 1,
        season_count: 1,
        tmdb_id: "tt1234567"
      })

    %Series{}
    |> Series.changeset(params)
    |> Repo.insert!()
  end

  defp season_fixture(series, attrs \\ %{}) do
    params =
      Enum.into(attrs, %{
        season_number: 1,
        name: "Season 1",
        series_id: series.id,
        episode_count: 0
      })

    %Season{}
    |> Season.changeset(params)
    |> Repo.insert!()
  end

  defp plan_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    params =
      Enum.into(attrs, %{
        name: "Premium #{unique}",
        slug: "premium-#{unique}",
        description: "Access to global content",
        price_cents: 1_999,
        currency: "USD",
        billing_interval: "month",
        active: true,
        grants_global_access: true
      })

    %Plan{}
    |> Plan.changeset(params)
    |> Repo.insert!()
  end

  defp create_subscription!(user, plan, attrs \\ %{}) do
    params =
      Enum.into(attrs, %{
        status: "active",
        starts_at: DateTime.add(DateTime.utc_now(), -1, :day),
        expires_at: DateTime.add(DateTime.utc_now(), 1, :day),
        canceled_at: nil,
        source: "stripe",
        external_reference: "sub_#{System.unique_integer([:positive])}"
      })

    %Subscription{}
    |> Subscription.create_changeset(user, plan, params)
    |> Repo.insert!()
  end

  describe "premium detail signals" do
    setup do
      user = user_fixture()

      provider =
        provider_fixture(user, %{
          visibility: "global",
          is_system: true,
          provider_type: "xtream",
          is_active: true
        })

      movie =
        movie_fixture(provider, %{
          name: "A Premium Movie",
          plot: "Movie plot",
          cast: "Cast",
          director: "Director",
          content_rating: "14",
          tagline: "Movie tagline",
          images: ["https://example.com/movie.jpg"]
        })

      series =
        series_fixture(provider, %{
          name: "A Premium Series",
          plot: "Series plot",
          cast: "Cast",
          director: "Director",
          content_rating: "14",
          tagline: "Series tagline"
        })

      _season = season_fixture(series)

      %{user: user, movie: movie, series: series}
    end

    test "movie detail browse shows premium badge and cta for non-entitled users", %{
      conn: conn,
      user: user,
      movie: movie
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse/movies/#{movie.id}")

      assert has_element?(view, "#movie-detail-premium-cta")
      assert has_element?(view, "[data-premium-badge]")
    end

    test "movie detail browse keeps premium badge visible for entitled users", %{
      conn: conn,
      user: user,
      movie: movie
    } do
      plan = plan_fixture()
      _subscription = create_subscription!(user, plan)

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse/movies/#{movie.id}")

      assert has_element?(view, "[data-premium-badge]")
      refute has_element?(view, "#movie-detail-premium-cta")
    end

    test "series detail browse shows premium badge and cta for non-entitled users", %{
      conn: conn,
      user: user,
      series: series
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse/series/#{series.id}")

      assert has_element?(view, "#series-detail-premium-cta")
      assert has_element?(view, "[data-premium-badge]")
    end

    test "series detail browse keeps premium badge visible for entitled users", %{
      conn: conn,
      user: user,
      series: series
    } do
      plan = plan_fixture()
      _subscription = create_subscription!(user, plan)

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse/series/#{series.id}")

      assert has_element?(view, "[data-premium-badge]")
      refute has_element?(view, "#series-detail-premium-cta")
    end
  end
end
