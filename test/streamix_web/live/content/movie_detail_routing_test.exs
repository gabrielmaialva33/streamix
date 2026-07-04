defmodule StreamixWeb.Content.MovieDetailRoutingTest do
  use StreamixWeb.ConnCase

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  # Regression: the browse mount clause used to match provider routes too
  # (its pattern matched any params with "id" and no on_mount ever set the
  # :provider assign), so /providers/:provider_id/... silently mounted with
  # the global provider instead of validating access to the one in the URL.
  describe "mount routing" do
    setup do
      user = user_fixture()

      provider =
        provider_fixture(user, %{
          visibility: "global",
          is_system: true,
          provider_type: "xtream",
          is_active: true
        })

      # plot + content_rating present so the detail page skips the live
      # Xtream/TMDB enrichment call.
      movie =
        movie_fixture(provider, %{
          name: "Routed Movie",
          plot: "A movie used to pin mount routing.",
          content_rating: "16"
        })

      %{user: user, provider: provider, movie: movie}
    end

    test "browse route mounts with the global provider", ctx do
      conn = log_in_user(ctx.conn, ctx.user)

      {:ok, _view, html} = live(conn, ~p"/browse/movies/#{ctx.movie.id}")

      assert html =~ "Routed Movie"
    end

    test "provider route resolves the provider from the URL", ctx do
      conn = log_in_user(ctx.conn, ctx.user)

      {:ok, _view, html} = live(conn, ~p"/providers/#{ctx.provider.id}/movies/#{ctx.movie.id}")

      assert html =~ "Routed Movie"
    end

    test "provider route back link honors a safe return path", ctx do
      conn = log_in_user(ctx.conn, ctx.user)

      {:ok, view, _html} =
        live(
          conn,
          ~p"/providers/#{ctx.provider.id}/movies/#{ctx.movie.id}?return_to=/browse/movies/#{ctx.movie.id}"
        )

      assert has_element?(view, ~s(a[href="/browse/movies/#{ctx.movie.id}"]))
    end

    test "provider route ignores unsafe return paths", ctx do
      conn = log_in_user(ctx.conn, ctx.user)

      {:ok, view, _html} =
        live(conn, ~p"/providers/#{ctx.provider.id}/movies/#{ctx.movie.id}?return_to=//evil.test")

      assert has_element?(view, ~s(a[href="/providers/#{ctx.provider.id}/movies"]))
      refute has_element?(view, ~s(a[href="//evil.test"]))
    end

    test "provider route with inaccessible provider redirects home", ctx do
      conn = log_in_user(ctx.conn, ctx.user)

      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn, ~p"/providers/999999/movies/#{ctx.movie.id}")
    end

    test "browse route with malformed movie id redirects instead of crashing", ctx do
      conn = log_in_user(ctx.conn, ctx.user)

      assert {:error, {:live_redirect, %{to: "/browse/movies"}}} =
               live(conn, ~p"/browse/movies/not-a-number")
    end

    test "browse route opens a visible private movie without a global provider", %{conn: conn} do
      user = user_fixture()
      provider = provider_fixture(user, %{name: "Private Detail Catalog"})

      movie =
        movie_fixture(provider, %{
          name: "Private Detail Movie",
          plot: "Visible private movie.",
          content_rating: "14",
          tmdb_id: "private-detail-movie"
        })

      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/browse/movies/#{movie.id}")

      assert html =~ "Private Detail Movie"
    end

    test "browse route blocks another user's private movie", %{conn: conn} do
      user = user_fixture()
      owner = user_fixture()
      provider = provider_fixture(owner, %{name: "Other Private Detail Catalog"})

      movie =
        movie_fixture(provider, %{
          name: "Other Private Detail Movie",
          plot: "Private movie.",
          content_rating: "14",
          tmdb_id: "other-private-detail-movie"
        })

      conn = log_in_user(conn, user)

      assert {:error, {:live_redirect, %{to: "/browse/movies"}}} =
               live(conn, ~p"/browse/movies/#{movie.id}")
    end
  end
end
