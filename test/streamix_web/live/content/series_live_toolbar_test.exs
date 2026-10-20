defmodule StreamixWeb.Content.SeriesLiveToolbarTest do
  use StreamixWeb.ConnCase

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Cache
  alias Streamix.Cache.Keys
  alias Streamix.Iptv.{Category, Genre}
  alias Streamix.Repo

  setup do
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

  describe "category sidebar" do
    test "browse mode only lists and applies categories after a provider is selected", %{
      conn: conn,
      user: user,
      global: global
    } do
      category =
        Repo.insert!(%Category{
          provider_id: global.id,
          name: "Toolbar test category",
          type: "series",
          external_id: "series-toolbar-test"
        })

      tagged = series_content_fixture(global, %{name: "Tagged Show", series_id: 2_401})
      untagged = series_content_fixture(global, %{name: "Untagged Show", series_id: 2_402})

      Repo.insert_all("item_categories", [
        %{catalog_item_id: tagged.catalog_item_id, category_id: category.id}
      ])

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse/series")

      refute has_element?(view, "button", "Toolbar test category")
      assert has_element?(view, "#series-card-#{tagged.id}")
      assert has_element?(view, "#series-card-#{untagged.id}")

      {:ok, view, _html} = live(conn, ~p"/browse/series?category=#{category.id}")

      refute has_element?(view, "button", "Toolbar test category")
      assert has_element?(view, "#series-card-#{tagged.id}")
      assert has_element?(view, "#series-card-#{untagged.id}")

      {:ok, view, _html} = live(conn, ~p"/browse/series?provider=#{global.id}")

      assert has_element?(view, "button", "Toolbar test category")

      {:ok, view, _html} =
        live(conn, ~p"/browse/series?provider=#{global.id}&category=#{category.id}")

      assert has_element?(view, ".category-pill--sidebar-active", "Toolbar test category")
      assert has_element?(view, "#series-card-#{tagged.id}")
      refute has_element?(view, "#series-card-#{untagged.id}")
    end

    test "all-providers browse renders canonical genre filter with counts, patches ?genre, and drops it when selecting a provider",
         %{conn: conn, user: user, global: global} do
      drama =
        Repo.insert!(
          %Genre{slug: "drama", name: "Drama", position: 7},
          on_conflict: {:replace, [:name, :position]},
          conflict_target: :slug
        )
        |> then(fn _ -> Repo.get_by!(Genre, slug: "drama") end)

      comedia =
        Repo.insert!(
          %Genre{slug: "comedia", name: "Comédia", position: 4},
          on_conflict: {:replace, [:name, :position]},
          conflict_target: :slug
        )
        |> then(fn _ -> Repo.get_by!(Genre, slug: "comedia") end)

      dramatic = series_content_fixture(global, %{name: "Dramatic Series", series_id: 2_501})
      funny = series_content_fixture(global, %{name: "Funny Series", series_id: 2_502})

      Repo.insert_all("series_genres", [
        %{series_id: dramatic.id, genre_id: drama.id},
        %{series_id: funny.id, genre_id: comedia.id}
      ])

      Cache.delete(Keys.visible_genres(:series, user.id, false))

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse/series")

      assert has_element?(view, "#genre-filter")
      assert has_element?(view, "#genre-all.category-pill--sidebar-active")
      assert has_element?(view, "#genre-comedia", "Comédia")
      assert has_element?(view, "#genre-drama", "Drama")
      assert has_element?(view, "#series-card-#{dramatic.id}")
      assert has_element?(view, "#series-card-#{funny.id}")

      view |> element("#genre-drama") |> render_click()
      assert_patch(view, "/browse/series?genre=drama")
      assert has_element?(view, "#genre-drama.category-pill--sidebar-active")
      assert has_element?(view, "#series-card-#{dramatic.id}")
      refute has_element?(view, "#series-card-#{funny.id}")

      # Reset back to Todos
      view |> element("#genre-all") |> render_click()
      assert_patch(view, "/browse/series")
      assert has_element?(view, "#series-card-#{dramatic.id}")
      assert has_element?(view, "#series-card-#{funny.id}")

      # Switching provider drops genre
      {:ok, view, _html} = live(conn, ~p"/browse/series?genre=drama")
      render_hook(view, "filter_provider", %{"provider" => Integer.to_string(global.id)})
      assert_patch(view, "/browse/series?provider=#{global.id}")
      refute has_element?(view, "#genre-filter")
    end
  end
end
