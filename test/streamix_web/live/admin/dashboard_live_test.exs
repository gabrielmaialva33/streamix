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

  describe "dashboard content" do
    setup %{conn: conn} do
      admin = admin_user_fixture()
      conn = log_in_user(conn, admin)
      %{conn: conn, admin: admin}
    end

    test "shows stat cards", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin")
      assert html =~ "Total Usuários"
      assert html =~ "Subscriptions Ativas"
      assert html =~ "Planos Ativos"
      assert html =~ "Receita Mensal"
    end

    test "shows recent users table", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin")
      assert html =~ "Últimos Usuários"
    end

    test "shows admin tabs", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin")
      assert html =~ "Dashboard"
      assert html =~ "Planos"
      assert html =~ "Usuários"
    end
  end
end
