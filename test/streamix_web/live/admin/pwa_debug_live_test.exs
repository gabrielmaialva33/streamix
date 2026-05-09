defmodule StreamixWeb.Admin.PwaDebugLiveTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures

  test "redirects unauthenticated users to login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/debug/pwa")
  end

  test "redirects non-admin users to home", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/debug/pwa")
  end

  test "renders diagnostics shell for admins", %{conn: conn} do
    conn = log_in_user(conn, admin_user_fixture())

    assert {:ok, _lv, html} = live(conn, ~p"/debug/pwa")
    assert html =~ "PWA / iOS Safari"
    assert html =~ "Baixar TXT"
    assert html =~ "phx-hook=\"PwaDebug\""
    assert html =~ "data-server-debug="
  end
end
