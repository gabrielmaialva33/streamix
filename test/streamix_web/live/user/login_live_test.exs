defmodule StreamixWeb.User.LoginLiveTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "keeps persistent login enabled without racing browser autofill", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/login")

    assert has_element?(view, "#user_remember_me[checked]")
    assert has_element?(view, "label.min-h-11 #user_remember_me")
    refute has_element?(view, "form[phx-change]")
  end
end
