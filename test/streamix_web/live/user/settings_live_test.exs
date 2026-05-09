defmodule StreamixWeb.User.SettingsLiveTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures

  test "renders PWA repair tools for authenticated users", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    assert {:ok, _lv, html} = live(conn, ~p"/settings")
    assert html =~ "App no iPhone"
    assert html =~ "Atualizar app e limpar cache"
    assert html =~ "phx-hook=\"PwaRepair\""
  end
end
