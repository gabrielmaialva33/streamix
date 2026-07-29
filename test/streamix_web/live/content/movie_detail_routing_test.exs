defmodule StreamixWeb.Content.MovieDetailRoutingTest do
  use StreamixWeb.ConnCase

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Repo
  alias Streamix.Torrent.TorrentStream

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

    test "play uses a full redirect when entering the player live session", ctx do
      conn = log_in_user(ctx.conn, ctx.user)
      {:ok, view, _html} = live(conn, ~p"/browse/movies/#{ctx.movie.id}")

      view
      |> element(~s(button[phx-click="play_movie"]))
      |> render_click()

      assert_redirect(
        view,
        "/watch/movie/#{ctx.movie.id}?return_to=%2Fbrowse%2Fmovies%2F#{ctx.movie.id}"
      )
    end

    test "play keeps the original catalog return target through the detail page", ctx do
      conn = log_in_user(ctx.conn, ctx.user)
      origin = "/browse/movies?provider=#{ctx.provider.id}&search=Routed"

      detail_path =
        "/browse/movies/#{ctx.movie.id}?provider=#{ctx.provider.id}" <>
          "&return_to=#{URI.encode_www_form(origin)}"

      {:ok, view, _html} = live(conn, detail_path)

      view
      |> element(~s(button[phx-click="play_movie"]))
      |> render_click()

      assert_redirect(
        view,
        "/watch/movie/#{ctx.movie.id}?return_to=#{URI.encode_www_form(detail_path)}"
      )
    end

    test "version watch links do not request cross-session live navigation", ctx do
      conn = log_in_user(ctx.conn, ctx.user)
      {:ok, view, _html} = live(conn, ~p"/browse/movies/#{ctx.movie.id}")

      watch_path =
        "/watch/movie/#{ctx.movie.id}?return_to=%2Fbrowse%2Fmovies%2F#{ctx.movie.id}"

      assert has_element?(view, ~s|a[href="#{watch_path}"]:not([data-phx-link])|)
    end

    test "torrent version watch links enter the swarm gate", %{conn: conn} do
      user = user_fixture()

      provider =
        global_provider_fixture(%{
          name: "Torrent Detail Catalog",
          provider_type: :torrent
        })

      movie =
        movie_fixture(provider, %{
          name: "Torrent Routed Movie",
          title: "Torrent Routed Movie",
          plot: "A torrent movie used to pin playback routing.",
          content_rating: "14",
          tmdb_id: "torrent-routed-movie"
        })

      info_hash =
        System.unique_integer([:positive])
        |> Integer.to_string(16)
        |> String.pad_leading(40, "0")

      stream =
        %TorrentStream{}
        |> TorrentStream.changeset(%{
          info_hash: info_hash,
          magnet_uri: "magnet:?xt=urn:btih:#{info_hash}",
          source_slug: "test",
          movie_id: movie.id,
          quality: "1080p",
          seeders: 10
        })
        |> Repo.insert!()

      conn = log_in_user(conn, user)
      detail_path = ~p"/providers/#{provider.id}/movies/#{movie.id}"
      {:ok, view, _html} = live(conn, detail_path)
      watch_path = "/watch/torrent/#{stream.id}?return_to=#{URI.encode_www_form(detail_path)}"

      assert has_element?(view, ~s|a[href="#{watch_path}"]:not([data-phx-link])|)
      refute has_element?(view, ~s|a[href="/watch/movie/#{movie.id}"]|)
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

      assert {:error, {:redirect, %{to: "/"}}} =
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
