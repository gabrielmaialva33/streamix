defmodule StreamixWeb.Content.SeriesLivePremiumSignalsTest do
  use StreamixWeb.ConnCase

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv
  alias Streamix.Iptv.{CatalogItem, Series}
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

  describe "premium signals" do
    setup do
      user = user_fixture()

      global_provider =
        provider_fixture(user, %{
          visibility: "global",
          is_system: true,
          provider_type: "xtream",
          is_active: true
        })

      featured_series =
        series_fixture(global_provider, %{name: "A Premium Series", tmdb_id: "premium-series"})

      owned_provider = provider_fixture(user)

      _owned_series =
        series_fixture(owned_provider, %{name: "A Private Series", tmdb_id: "private-series"})

      %{
        user: user,
        featured_series: featured_series,
        owned_provider: owned_provider
      }
    end

    test "shows premium cta banner and badge in browse mode", %{
      conn: conn,
      user: user,
      featured_series: featured_series
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse/series")

      assert has_element?(view, "#browse-premium-cta")
      assert render(view |> element("#browse-premium-cta a")) =~ ~s(href="/plans")
      assert has_element?(view, "#series-card-#{featured_series.id} [data-premium-badge]")
    end

    test "does not show premium cta banner in provider mode", %{
      conn: conn,
      user: user,
      owned_provider: owned_provider
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/providers/#{owned_provider.id}/series")

      refute has_element?(view, "#browse-premium-cta")
      refute has_element?(view, "#browse-premium-cta a[href=\"/plans\"]")
    end
  end

  describe "provider filter" do
    test "forged favorite event cannot favorite another user's private series", %{conn: conn} do
      user = user_fixture()
      owner = user_fixture()
      private_provider = provider_fixture(owner, %{name: "Other Private Catalog"})
      private_series = series_content_fixture(private_provider, %{name: "Other Private Series"})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse/series")

      render_hook(view, "toggle_favorite", %{"id" => private_series.id, "type" => "series"})

      refute Iptv.favorite?(user.id, "series", private_series.id)
    end
  end
end
