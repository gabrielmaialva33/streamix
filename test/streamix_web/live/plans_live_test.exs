defmodule StreamixWeb.PlansLiveTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Streamix.Billing
  alias Streamix.Billing.{Plan, Subscription}
  alias Streamix.Repo

  defp plan_fixture(attrs \\ %{}) do
    params =
      Enum.into(attrs, %{
        name: "Premium",
        slug: "premium",
        description: "Acesso global ao catálogo e recursos premium.",
        price_cents: 1_999,
        currency: "BRL",
        billing_interval: "month",
        active: true,
        grants_global_access: true
      })

    %Plan{}
    |> Plan.changeset(params)
    |> Repo.insert!()
  end

  defp subscription_fixture(user, plan, attrs \\ %{}) do
    params =
      Enum.into(attrs, %{
        status: "active",
        starts_at: DateTime.utc_now(),
        expires_at: nil,
        canceled_at: nil,
        source: "stripe",
        external_reference: "sub_test"
      })

    %Subscription{}
    |> Subscription.create_changeset(user, plan, params)
    |> Repo.insert!()
  end

  describe "guest access" do
    test "guest can access /plans", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/plans")

      assert html =~ "plans-page"
      assert has_element?(view, "#plans-page")
      assert has_element?(view, "#plans-list")
    end
  end

  describe "authenticated access" do
    setup :register_and_log_in_user

    test "logged in user sees plans page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/plans")

      assert has_element?(view, "#plans-page")
      assert has_element?(view, "#plans-list")
    end

    test "shows the active subscription state for the current user", %{conn: conn, user: user} do
      plan = plan_fixture()
      _subscription = subscription_fixture(user, plan)

      {:ok, view, _html} = live(conn, ~p"/plans")

      assert has_element?(view, "#current-subscription[data-status='active']")
      assert render(view) =~ plan.name
    end
  end

  describe "billing plans" do
    setup :register_and_log_in_user

    test "renders only active plans", %{conn: conn, user: user} do
      active_plan = plan_fixture(name: "Ativo", slug: "ativo")
      _inactive_plan = plan_fixture(name: "Inativo", slug: "inativo", active: false)
      _subscription = subscription_fixture(user, active_plan)

      {:ok, view, _html} = live(conn, ~p"/plans")

      assert has_element?(view, "#plan-card-ativo")
      refute has_element?(view, "#plan-card-inativo")
      assert Billing.list_active_plans() |> Enum.map(& &1.slug) == ["ativo"]
    end
  end
end
