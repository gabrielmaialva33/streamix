defmodule StreamixWeb.Admin.PlansLiveTest do
  use StreamixWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures

  alias Streamix.Billing
  alias Streamix.Billing.PlanFeature

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
          billing_interval: "year",
          stripe_price_id: "price_anual",
          trial_days: 7
        }
      )
      |> render_submit()

      assert_redirected(lv, ~p"/admin/plans")

      plans = Billing.list_plans()
      assert Enum.any?(plans, &(&1.slug == "anual" and &1.stripe_price_id == "price_anual"))
      assert Enum.any?(plans, &(&1.slug == "anual" and &1.trial_days == 7))
    end

    test "creates plan feature limits", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/plans/new")

      lv
      |> form("#plan-form",
        plan: %{
          name: "Operador",
          slug: "operador",
          description: "Plano operador",
          price_cents: 4990,
          currency: "BRL",
          billing_interval: "month",
          features: %{
            global_catalog: "true",
            ai_recommendations: "false",
            watch_party: "true",
            max_providers: "5",
            concurrent_streams: "2"
          }
        }
      )
      |> render_submit()

      assert_redirected(lv, ~p"/admin/plans")

      plan = Billing.list_plans() |> Enum.find(&(&1.slug == "operador"))
      features = Streamix.Repo.all(from(f in PlanFeature, where: f.plan_id == ^plan.id))

      assert Enum.any?(features, &(&1.feature == "global_catalog" and &1.enabled))
      assert Enum.any?(features, &(&1.feature == "watch_party" and &1.enabled))
      assert Enum.any?(features, &(&1.feature == "max_providers" and &1.limit == 5))
      assert Enum.any?(features, &(&1.feature == "concurrent_streams" and &1.limit == 2))
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
