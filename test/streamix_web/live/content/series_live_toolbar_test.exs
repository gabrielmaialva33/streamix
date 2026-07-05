defmodule StreamixWeb.Content.SeriesLiveToolbarTest do
  use StreamixWeb.ConnCase

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Cache
  alias Streamix.Iptv.Genre
  alias Streamix.Repo

  setup do
    Cache.delete("catalog:genres:series")
    on_exit(fn -> Cache.delete("catalog:genres:series") end)

    user = user_fixture()

    global =
      provider_fixture(user, %{
        name: "Global Catalog",
        visibility: "global",
        is_system: true,
        provider_type: "xtream",
        is_active: true
      })

    %{user: user, global: global}
  end

  describe "provider dropdown" do
    test "browse mode renders the dropdown without a Todos chip", %{
      conn: conn,
      user: user,
      global: global
    } do
      _series = series_content_fixture(global, %{name: "Any Show"})

      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/browse/series")

      assert has_element?(view, "#provider-dropdown")
      assert has_element?(view, "#provider-dropdown-menu button", global.name)
      refute html =~ ">Todos</button>"
    end

    test "selecting a provider marks it active in the dropdown", %{
      conn: conn,
      user: user,
      global: global
    } do
      _series = series_content_fixture(global, %{name: "Any Show"})

      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/browse/series?provider=#{global.id}&search=tagged")

      assert has_element?(view, "#provider-dropdown [aria-selected=\"true\"]", global.name)
      assert has_element?(view, "#provider-dropdown [aria-label=\"Limpar filtro de provedor\"]")
      assert html =~ ~s(href="/browse?provider=#{global.id}&amp;search=tagged")
      assert html =~ ~s(href="/browse/movies?provider=#{global.id}&amp;search=tagged")
    end
  end

  describe "unified genre sidebar" do
    test "browse mode lists canonical genres and filters by them", %{
      conn: conn,
      user: user,
      global: global
    } do
      genre = Repo.insert!(%Genre{name: "toolbar test genre"})

      tagged = series_content_fixture(global, %{name: "Tagged Show", series_id: 2_401})
      untagged = series_content_fixture(global, %{name: "Untagged Show", series_id: 2_402})

      Repo.insert_all("series_genres", [%{series_id: tagged.id, genre_id: genre.id}])

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse/series")

      assert has_element?(view, "button", "Toolbar test genre")
      assert has_element?(view, "#series-card-#{tagged.id}")
      assert has_element?(view, "#series-card-#{untagged.id}")

      {:ok, view, _html} = live(conn, ~p"/browse/series?category=#{genre.id}")

      assert has_element?(view, "#series-card-#{tagged.id}")
      refute has_element?(view, "#series-card-#{untagged.id}")
    end
  end
end
