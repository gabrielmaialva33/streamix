defmodule StreamixWeb.OnMount.ThemeEventsTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "consumes the client-only theme event before the LiveView callback", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/login")

    assert is_binary(render_hook(view, "theme_init", %{}))
  end
end
