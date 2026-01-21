defmodule StreamixWeb.Content.MoviesLiveTest do
  use StreamixWeb.ConnCase

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

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

      # Create 50 movies (2 pages + 2 items)
      for i <- 1..50 do
        movie_fixture(provider, %{name: "Movie #{i}"})
      end

      %{user: user, provider: provider}
    end

    test "loads more movies when load_more event is triggered", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse/movies")

      # Initial load should have 24 items
      assert view |> has_element?("#movies > div:nth-child(24)")
      refute view |> has_element?("#movies > div:nth-child(25)")

      # Trigger load_more
      view |> render_hook("load_more", %{})

      # Should now have 48 items
      assert view |> has_element?("#movies > div:nth-child(48)")
    end
  end
end
