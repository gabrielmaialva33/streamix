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
      assert has_element?(view, "#search-filter-strip[data-filter-strip]")

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

    test "initial and empty states provide bounded status surfaces", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)
      {:ok, initial_view, _html} = live(conn, ~p"/search")

      assert has_element?(initial_view, "#search-hints.border")

      {:ok, empty_view, html} = live(conn, ~p"/search?q=zzzz-no-streamix-result-zzzz")

      assert has_element?(empty_view, "#search-empty[role='status']")
      assert html =~ "zzzz-no-streamix-result-zzzz"
    end

    test "renders the complete first page and can load every remaining result", %{
      conn: conn,
      user: user,
      global: global
    } do
      movies =
        for index <- 1..25 do
          suffix = String.pad_leading(Integer.to_string(index), 2, "0")

          movie_fixture(global, %{
            name: "Busca Completa #{suffix}",
            title: "Busca Completa #{suffix}"
          })
        end

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/search?q=Busca+Completa")

      assert has_element?(view, "#movie-card-#{Enum.at(movies, 6).id}")
      assert has_element?(view, "#movie-card-#{Enum.at(movies, 23).id}")
      refute has_element?(view, "#movie-card-#{Enum.at(movies, 24).id}")
      assert has_element?(view, "#search-load-more-movies[phx-click='load_more']")

      view
      |> element("#search-load-more-movies")
      |> render_click()

      assert has_element?(view, "#movie-card-#{Enum.at(movies, 24).id}")
      refute has_element?(view, "#search-load-more-movies")

      view
      |> element("#movie-card-#{Enum.at(movies, 24).id} button[phx-click='toggle_favorite']")
      |> render_click()

      assert has_element?(view, "#movie-card-#{Enum.at(movies, 24).id}")

      assert has_element?(
               view,
               "#movie-card-#{Enum.at(movies, 24).id} button[aria-label='Remover dos favoritos']"
             )

      refute has_element?(view, "#search-load-more-movies")
    end

    test "does not truncate channel and series sections to six cards", %{
      conn: conn,
      user: user,
      global: global
    } do
      channels =
        for index <- 1..7 do
          channel_fixture(global, %{name: "Busca Sete Canal #{index}"})
        end

      series =
        for index <- 1..7 do
          series_content_fixture(global, %{
            name: "Busca Sete Série #{index}",
            title: "Busca Sete Série #{index}"
          })
        end

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/search?q=Busca+Sete")

      assert has_element?(view, "#channel-img-#{List.last(channels).id}")
      assert has_element?(view, "#series-card-#{List.last(series).id}")
    end

    test "keeps streamed cards mounted while switching filters", %{
      conn: conn,
      user: user,
      global: global
    } do
      channel = channel_fixture(global, %{name: "Busca Persistente Canal"})

      movie =
        movie_fixture(global, %{
          name: "Busca Persistente Filme",
          title: "Busca Persistente Filme"
        })

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/search?q=Busca+Persistente")

      view |> element("button[phx-value-type='channels']") |> render_click()
      assert has_element?(view, "#channel-img-#{channel.id}")

      view |> element("button[phx-value-type='all']") |> render_click()
      assert has_element?(view, "#movie-card-#{movie.id}")
    end
  end
end
