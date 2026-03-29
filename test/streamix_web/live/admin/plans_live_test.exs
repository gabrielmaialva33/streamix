defmodule StreamixWeb.Admin.PlansLiveTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures

  alias Streamix.Billing

  @plan_attrs %{
    name: "Premium",
    slug: "premium",
    description: "Full access",
    price_cents: 1999,
    currency: "BRL",
    billing_interval: "month"
  }

  setup %{conn: conn} do
    admin = admin_user_fixture()
    conn = log_in_user(conn, admin)

    # Delete all pre-existing plans (seeds may have inserted them)
    Streamix.Repo.delete_all(Streamix.Billing.Plan)

    %{conn: conn}
  end

  describe "plans listing" do
    test "shows plans table", %{conn: conn} do
      {:ok, _plan} = Billing.create_plan(@plan_attrs)
      {:ok, _lv, html} = live(conn, ~p"/admin/plans")
      assert html =~ "Premium"
      assert html =~ "month"
    end

    test "shows empty state when no plans", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/plans")
      assert html =~ "Nenhum plano"
    end
  end

  describe "plan creation" do
    test "creates plan with valid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/plans/new")

      lv
      |> form("#plan-form",
        plan: %{
          name: "Anual",
          slug: "anual",
          description: "Plano anual",
          price_cents: 9990,
          currency: "BRL",
          billing_interval: "year"
        }
      )
      |> render_submit()

      assert_redirected(lv, ~p"/admin/plans")

      plans = Billing.list_plans()
      assert Enum.any?(plans, &(&1.slug == "anual"))
    end

    test "rejects invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/plans/new")

      lv
      |> form("#plan-form", plan: %{name: "", slug: ""})
      |> render_submit()

      # Stays on form (no plan created)
      assert render(lv) =~ "Novo Plano"
      assert Billing.list_plans() == []
    end
  end

  describe "plan editing" do
    test "updates plan", %{conn: conn} do
      {:ok, plan} = Billing.create_plan(@plan_attrs)
      {:ok, lv, _html} = live(conn, ~p"/admin/plans/#{plan.id}")

      lv
      |> form("#plan-form", plan: %{name: "Premium Plus"})
      |> render_submit()

      assert_redirected(lv, ~p"/admin/plans")
      assert Billing.get_plan!(plan.id).name == "Premium Plus"
    end
  end
end
