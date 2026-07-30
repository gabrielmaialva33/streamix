defmodule StreamixWeb.Content.DetailPremiumSignalsTest do
  use StreamixWeb.ConnCase

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  alias Streamix.Billing.{Plan, Subscription}
  import Streamix.IptvFixtures

  alias Streamix.Iptv.{CatalogItem, Episode, Season, Series}
  alias Streamix.Repo

  defp series_fixture(provider, attrs) do
    catalog_item =
      %CatalogItem{}
      |> CatalogItem.changeset(%{content_type: "series", provider_id: provider.id})
      |> Repo.insert!()

    params =
      Enum.into(attrs, %{
        series_id: System.unique_integer([:positive]),
        name: "Series #{System.unique_integer([:positive])}",
        title: "Series Title #{System.unique_integer([:positive])}",
        year: 2024,
        provider_id: provider.id,
        tmdb_id: "tt1234567",
        catalog_item_id: catalog_item.id
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
        series_id: series.id
      })

    %Season{}
    |> Season.changeset(params)
    |> Repo.insert!()
  end

  defp episode_fixture(season, provider) do
    ci =
      %CatalogItem{}
      |> CatalogItem.changeset(%{content_type: "episode", provider_id: provider.id})
      |> Repo.insert!()

    %Episode{}
    |> Episode.changeset(%{
      episode_id: System.unique_integer([:positive]),
      episode_num: 1,
      title: "Episode 1",
      season_id: season.id,
      catalog_item_id: ci.id
    })
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
          content_rating: "14",
          tagline: "Movie tagline",
          tmdb_id: "67890"
        })

      series =
        series_fixture(provider, %{
          name: "A Premium Series",
          plot: "Series plot",
          content_rating: "14",
          tagline: "Series tagline",
          tmdb_id: "12345"
        })

      season = season_fixture(series)
      episode_fixture(season, provider)

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
      assert render_async(view) =~ "A Premium Movie"
    end

    test "movie detail browse hides premium badge and cta for entitled users", %{
      conn: conn,
      user: user,
      movie: movie
    } do
      plan = plan_fixture()
      _subscription = create_subscription!(user, plan)

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse/movies/#{movie.id}")

      refute has_element?(view, "[data-premium-badge]")
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
      assert render_async(view) =~ "A Premium Series"
    end

    test "series detail browse hides premium badge and cta for entitled users", %{
      conn: conn,
      user: user,
      series: series
    } do
      plan = plan_fixture()
      _subscription = create_subscription!(user, plan)

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse/series/#{series.id}")

      refute has_element?(view, "[data-premium-badge]")
      refute has_element?(view, "#series-detail-premium-cta")
    end

    test "series detail recommends one source and collapses the alternatives", %{
      conn: conn,
      user: user,
      series: series
    } do
      alternative_provider =
        provider_fixture(user, %{
          name: "Alternative Series Provider",
          is_active: true
        })

      alternative_series =
        series_fixture(alternative_provider, %{
          name: "A Premium Series Alternative",
          title: series.title,
          plot: "Alternative source.",
          content_rating: "14",
          tmdb_id: series.tmdb_id
        })

      alternative_series
      |> season_fixture()
      |> episode_fixture(alternative_provider)

      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/browse/series/#{series.id}")
      document = Floki.parse_document!(html)

      assert length(
               Floki.find(document, "#recommended-series-source [data-source-card='series']")
             ) == 1

      assert has_element?(view, "#recommended-series-source #series-source-#{series.id}")
      assert has_element?(view, "details#alternative-series-sources:not([open])")

      assert has_element?(
               view,
               "#alternative-series-sources #series-source-#{alternative_series.id}"
             )
    end

    test "series detail browse opens a visible private series without a global provider", %{
      conn: conn
    } do
      user = user_fixture()
      provider = provider_fixture(user, %{name: "Private Series Detail Catalog"})

      series =
        series_fixture(provider, %{
          name: "Private Detail Series",
          plot: "Visible private series.",
          content_rating: "14",
          tmdb_id: "private-detail-series"
        })

      season = season_fixture(series)
      episode_fixture(season, provider)

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/browse/series/#{series.id}")

      assert html =~ "Private Detail Series"
    end

    test "series detail browse blocks another user's private series", %{conn: conn} do
      user = user_fixture()
      owner = user_fixture()
      provider = provider_fixture(owner, %{name: "Other Private Series Detail Catalog"})

      series =
        series_fixture(provider, %{
          name: "Other Private Detail Series",
          plot: "Private series.",
          content_rating: "14",
          tmdb_id: "other-private-detail-series"
        })

      season = season_fixture(series)
      episode_fixture(season, provider)

      conn = log_in_user(conn, user)

      assert {:error, {:live_redirect, %{to: "/browse/series"}}} =
               live(conn, ~p"/browse/series/#{series.id}")
    end

    test "series detail browse with malformed id redirects instead of crashing", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      assert {:error, {:live_redirect, %{to: "/browse/series"}}} =
               live(conn, ~p"/browse/series/not-a-number")
    end
  end
end
