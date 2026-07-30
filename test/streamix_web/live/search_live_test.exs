defmodule StreamixWeb.SearchLiveTest do
  use StreamixWeb.ConnCase

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

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

  describe "result cards" do
    test "clicking a movie poster navigates to the movie detail", %{
      conn: conn,
      user: user,
      global: global
    } do
      movie = movie_fixture(global, %{name: "Search Click Movie", year: 2024})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/search?q=Search+Click")

      assert has_element?(view, "#movie-card-#{movie.id}")

      view
      |> element("#movie-card-#{movie.id} > [data-media-primary]")
      |> render_click()

      assert_redirect(
        view,
        "/browse/movies/#{movie.id}?return_to=%2Fsearch%3Fq%3DSearch%2BClick"
      )
    end

    test "clicking a series poster navigates to the series detail", %{
      conn: conn,
      user: user,
      global: global
    } do
      series = series_content_fixture(global, %{name: "Search Click Series", year: 2024})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/search?q=Search+Click")

      assert has_element?(view, "#series-card-#{series.id}")

      view
      |> element("#series-card-#{series.id} > [data-media-primary]")
      |> render_click()

      assert_redirect(
        view,
        "/browse/series/#{series.id}?return_to=%2Fsearch%3Fq%3DSearch%2BClick"
      )
    end
  end
end
