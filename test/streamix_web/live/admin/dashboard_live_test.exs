defmodule StreamixWeb.Admin.DashboardLiveTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures

  describe "admin guard" do
    test "redirects non-admin users to /", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")
    end

    test "redirects unauthenticated users to /login", %{conn: conn} do
      {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/admin")
    end

    test "allows admin users", %{conn: conn} do
      admin = admin_user_fixture()
      conn = log_in_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")
      assert html =~ "Dashboard"
    end
  end
end
