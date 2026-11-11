defmodule StreamixWeb.Gindex.MovieDetailLiveTest do
  use StreamixWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Streamix.IptvFixtures
  alias StreamixWeb.Gindex.MovieDetailLive

  setup :register_and_log_in_user

  test "mount initializes only user state without requiring a content ID" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_scope: %{user: %{id: 42}}}
    }

    assert {:ok, mounted} = MovieDetailLive.mount(%{}, %{}, socket)
    assert mounted.assigns.user_id == 42
    refute Map.has_key?(mounted.assigns, :movie)
  end

  test "patching a detail URL reloads the selected content", %{conn: conn, user: user} do
    provider = provider_fixture(user, %{provider_type: :gindex})

    first =
      movie_fixture(provider, %{
        name: "Primeiro título",
        title: "Primeiro título",
        gindex_path: "/Filmes/primeiro"
      })

    second =
      movie_fixture(provider, %{
        name: "Segundo título",
        title: "Segundo título",
        gindex_path: "/Filmes/segundo"
      })

    {:ok, view, _html} = live(conn, "/gindex/movies/#{first.id}")
    assert has_element?(view, "h1", "Primeiro título")
    render_patch(view, "/gindex/movies/#{second.id}")
    assert has_element?(view, "h1", "Segundo título")
    refute has_element?(view, "h1", "Primeiro título")
  end

  test "lists the other Drive copies of the title as versions", %{conn: conn, user: user} do
    provider = provider_fixture(user, %{provider_type: :gindex})

    shown =
      movie_fixture(provider, %{
        name: "Duna 1080p",
        title: "Duna",
        tmdb_id: "438631",
        gindex_path: "/Filmes/duna-1080"
      })

    other =
      movie_fixture(provider, %{
        name: "Duna 2021 4K Dublado",
        tmdb_id: "438631",
        gindex_path: "/Filmes/duna-4k"
      })

    {:ok, view, _html} = live(conn, "/gindex/movies/#{shown.id}")

    assert has_element?(view, "#gindex-versions", "Outra versão")
    assert has_element?(view, "#gindex-version-#{other.id}", "4K")
    assert has_element?(view, "#gindex-version-#{other.id}[href^='/gindex/movies/#{other.id}']")
    refute has_element?(view, "#gindex-version-#{shown.id}")
  end
end
