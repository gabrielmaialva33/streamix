defmodule StreamixWeb.Gindex.AnimeDetailLiveTest do
  use StreamixWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Streamix.IptvFixtures
  alias StreamixWeb.Gindex.AnimeDetailLive

  setup :register_and_log_in_user

  test "mount initializes only user state without requiring a content ID" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_scope: %{user: %{id: 42}}}
    }

    assert {:ok, mounted} = AnimeDetailLive.mount(%{}, %{}, socket)
    assert mounted.assigns.user_id == 42
    refute Map.has_key?(mounted.assigns, :anime)
  end

  test "patching a detail URL reloads the selected content", %{conn: conn, user: user} do
    provider = provider_fixture(user, %{provider_type: :gindex})

    first =
      series_content_fixture(provider, %{
        name: "Primeiro título",
        title: "Primeiro título",
        gindex_path: "/Animes/primeiro"
      })

    second =
      series_content_fixture(provider, %{
        name: "Segundo título",
        title: "Segundo título",
        gindex_path: "/Animes/segundo"
      })

    {:ok, view, _html} = live(conn, "/gindex/animes/#{first.id}")
    assert has_element?(view, "h1", "Primeiro título")
    render_patch(view, "/gindex/animes/#{second.id}")
    assert has_element?(view, "h1", "Segundo título")
    refute has_element?(view, "h1", "Primeiro título")
  end
end
