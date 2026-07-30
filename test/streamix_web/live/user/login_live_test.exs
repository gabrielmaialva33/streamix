defmodule StreamixWeb.User.LoginLiveTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "keeps persistent login enabled without racing browser autofill", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/login")

    assert has_element?(view, "#user_remember_me[checked]")
    assert has_element?(view, "label.min-h-11 #user_remember_me")
    assert has_element?(view, "#user_email[autocomplete='username']")
    assert has_element?(view, "#user_password[autocomplete='current-password']")
    refute has_element?(view, "form[phx-change]")
  end
end
