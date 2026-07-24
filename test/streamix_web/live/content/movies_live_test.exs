defmodule StreamixWeb.Content.MoviesLiveTest do
  use StreamixWeb.ConnCase

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv
  alias Streamix.Iptv.Category
  alias Streamix.Repo

  describe "Infinite Scroll" do
    setup do
      user = user_fixture()

      provider =
        provider_fixture(user, %{
          visibility: "global",
          is_system: true,
          provider_type: "xtream",
          is_active: true
        })

      featured_movie = movie_fixture(provider, %{name: "A Premium Movie"})

      # Create 50 movies (2 pages + a few remaining items)
      for i <- 1..50 do
        movie_fixture(provider, %{name: "Movie #{i}"})
      end

      %{user: user, provider: provider, featured_movie: featured_movie}
    end

    test "loads more movies when load_more event is triggered", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse/movies")

      # Initial load should fill one compact-grid page.
      assert view |> has_element?("#movies > div:nth-child(48)")
      refute view |> has_element?("#movies > div:nth-child(49)")

      # Trigger load_more
      view |> render_hook("load_more", %{})

      # Should now have the remaining movies.
      assert view |> has_element?("#movies > div:nth-child(51)")
      refute view |> has_element?("#movies > div:nth-child(52)")
    end

    test "restores all loaded pages from the URL", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse/movies?page=2")

      assert view |> has_element?("#movies > div:nth-child(51)")
      refute view |> has_element?("#movies > div:nth-child(52)")
    end

    test "detail navigation keeps the loaded page as its return target", %{
      conn: conn,
      user: user,
      featured_movie: movie
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse/movies?page=2")

      view
      |> element("#movie-img-fb-#{movie.id}")
      |> render_click()

      assert_redirect(
        view,
        "/browse/movies/#{movie.id}?return_to=%2Fbrowse%2Fmovies%3Fpage%3D2"
      )
    end
  end

  describe "provider filter" do
    test "provider=all lists visible movies even when no global provider exists", %{conn: conn} do
      user = user_fixture()
      provider = provider_fixture(user, %{name: "Private Catalog"})
      movie = movie_fixture(provider, %{name: "Private Browse Movie"})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse/movies")

      assert has_element?(view, "#movie-card-#{movie.id}")
    end

    test "categories are only shown and applied after a provider is selected", %{conn: conn} do
      user = user_fixture()
      provider = provider_fixture(user, %{name: "Private Movie Catalog"})

      category =
        Repo.insert!(%Category{
          provider_id: provider.id,
          name: "Ação",
          type: "vod",
          external_id: "vod-action"
        })

      matching = movie_fixture(provider, %{name: "Tagged Private Movie"})
      other = movie_fixture(provider, %{name: "Untagged Private Movie"})

      Repo.insert_all("item_categories", [
        %{catalog_item_id: matching.catalog_item_id, category_id: category.id}
      ])

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse/movies")

      refute has_element?(view, "button", "Ação")
      assert has_element?(view, "#movie-card-#{matching.id}")
      assert has_element?(view, "#movie-card-#{other.id}")

      {:ok, view, _html} = live(conn, ~p"/browse/movies?category=#{category.id}")

      refute has_element?(view, "button", "Ação")
      assert has_element?(view, "#movie-card-#{matching.id}")
      assert has_element?(view, "#movie-card-#{other.id}")

      {:ok, view, _html} = live(conn, ~p"/browse/movies?provider=#{provider.id}")

      assert has_element?(view, "button", "Ação")

      {:ok, view, _html} =
        live(conn, ~p"/browse/movies?provider=#{provider.id}&category=#{category.id}")

      assert has_element?(view, ".category-pill--sidebar-active", "Ação")
      assert has_element?(view, "#movie-card-#{matching.id}")
      refute has_element?(view, "#movie-card-#{other.id}")

      view
      |> element("#movie-img-fb-#{matching.id}")
      |> render_click()

      return_to =
        URI.encode_www_form("/browse/movies?category=#{category.id}&provider=#{provider.id}")

      assert_redirect(
        view,
        "/browse/movies/#{matching.id}?provider=#{provider.id}&return_to=#{return_to}"
      )
    end

    test "forged favorite event cannot favorite another user's private movie", %{conn: conn} do
      user = user_fixture()
      owner = user_fixture()
      private_provider = provider_fixture(owner, %{name: "Other Private Catalog"})
      private_movie = movie_fixture(private_provider, %{name: "Other Private Movie"})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse/movies")

      render_hook(view, "toggle_favorite", %{"id" => private_movie.id, "type" => "movie"})

      refute Iptv.favorite?(user.id, "movie", private_movie.id)
    end
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

      featured_movie = movie_fixture(global_provider, %{name: "A Premium Movie"})
      owned_provider = provider_fixture(user)
      _owned_movie = movie_fixture(owned_provider, %{name: "A Private Movie"})

      %{
        user: user,
        global_provider: global_provider,
        featured_movie: featured_movie,
        owned_provider: owned_provider
      }
    end

    test "shows premium cta banner and badge in browse mode", %{
      conn: conn,
      user: user,
      featured_movie: featured_movie
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse/movies")

      assert has_element?(view, "#browse-premium-cta")
      assert render(view |> element("#browse-premium-cta a")) =~ ~s(href="/plans")
      assert has_element?(view, "#movie-card-#{featured_movie.id} [data-premium-badge]")
    end

    test "does not show premium cta banner for gindex browse", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse/movies?source=gindex")

      refute has_element?(view, "#browse-premium-cta")
      refute has_element?(view, "#browse-premium-cta a[href=\"/plans\"]")
    end

    test "does not show premium cta banner in provider mode", %{
      conn: conn,
      user: user,
      owned_provider: owned_provider
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/providers/#{owned_provider.id}/movies")

      refute has_element?(view, "#browse-premium-cta")
      refute has_element?(view, "#browse-premium-cta a[href=\"/plans\"]")
    end
  end
end
