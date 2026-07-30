defmodule StreamixWeb.Admin.BillingLiveTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures

  describe "admin billing" do
    setup %{conn: conn} do
      admin = admin_user_fixture()
      %{conn: log_in_user(conn, admin)}
    end

    test "renders billing stats", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/billing")

      assert html =~ "Cobrança"
      assert has_element?(view, "#admin-billing")
      assert html =~ "Pagamentos recentes"
      assert html =~ "Faturas recentes"
      assert html =~ "Clientes"
      assert has_element?(view, "[data-admin-table='payments'].overflow-x-auto")
      assert has_element?(view, "[data-admin-table='invoices'].overflow-x-auto")
    end
  end
end
