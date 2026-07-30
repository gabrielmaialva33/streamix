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
      {:ok, view, html} = live(conn, ~p"/admin")
      assert html =~ "Total Usuários"
      assert html =~ "Assinaturas ativas"
      assert html =~ "Planos ativos"
      assert html =~ "Receita mensal"
      assert has_element?(view, "#admin-dashboard-stats.grid-cols-2")
      assert has_element?(view, "#web-vitals-slo")
      assert has_element?(view, "#web-vitals-mobile", "Mobile / PWA")
    end

    test "shows localized recent tables without page-level overflow", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin")
      assert html =~ "Últimos usuários"
      assert html =~ "Últimas assinaturas"
      assert html =~ "Perfil"
      assert has_element?(view, "[data-admin-table='recent-users'].overflow-x-auto")
      assert has_element?(view, "[data-admin-table='recent-subscriptions'].overflow-x-auto")
    end

    test "shows admin tabs", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin")
      assert html =~ "Dashboard"
      assert html =~ "Planos"
      assert html =~ "Cobrança"
      assert html =~ "Usuários"
      assert has_element?(view, "#admin-navigation[aria-label='Administração']")
    end
  end
end
