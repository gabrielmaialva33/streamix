defmodule Streamix.Billing.AdminTest do
  use Streamix.DataCase, async: true

  alias Streamix.Billing
  alias Streamix.Billing.Plan

  import Streamix.AccountsFixtures

  @valid_plan_attrs %{
    name: "Test Plan",
    slug: "test-plan",
    description: "A test plan",
    price_cents: 999,
    currency: "BRL",
    billing_interval: "month"
  }

  describe "list_plans/0" do
    test "returns all plans including inactive" do
      {:ok, _active} = Billing.create_plan(@valid_plan_attrs)

      {:ok, _inactive} =
        Billing.create_plan(Map.merge(@valid_plan_attrs, %{slug: "inactive", active: false}))

      plans = Billing.list_plans()
      slugs = Enum.map(plans, & &1.slug)
      assert "test-plan" in slugs
      assert "inactive" in slugs
    end
  end

  describe "get_plan!/1" do
    test "returns plan by id" do
      {:ok, plan} = Billing.create_plan(@valid_plan_attrs)
      assert Billing.get_plan!(plan.id).slug == "test-plan"
    end

    test "raises on missing id" do
      assert_raise Ecto.NoResultsError, fn -> Billing.get_plan!(0) end
    end
  end

  describe "create_plan/1" do
    test "creates plan with valid attrs" do
      assert {:ok, %Plan{} = plan} = Billing.create_plan(@valid_plan_attrs)
      assert plan.name == "Test Plan"
      assert plan.price_cents == 999
    end

    test "returns error with invalid attrs" do
      assert {:error, %Ecto.Changeset{}} = Billing.create_plan(%{})
    end

    test "returns error with duplicate slug" do
      {:ok, _} = Billing.create_plan(@valid_plan_attrs)
      assert {:error, changeset} = Billing.create_plan(@valid_plan_attrs)
      assert {"has already been taken", _} = changeset.errors[:slug]
    end
  end

  describe "update_plan/2" do
    test "updates plan with valid attrs" do
      {:ok, plan} = Billing.create_plan(@valid_plan_attrs)
      assert {:ok, updated} = Billing.update_plan(plan, %{name: "Updated"})
      assert updated.name == "Updated"
    end

    test "returns error with invalid attrs" do
      {:ok, plan} = Billing.create_plan(@valid_plan_attrs)
      assert {:error, %Ecto.Changeset{}} = Billing.update_plan(plan, %{price_cents: -1})
    end
  end

  describe "cancel_subscription!/1" do
    test "sets status to canceled and canceled_at" do
      user = user_fixture()
      {:ok, plan} = Billing.create_plan(@valid_plan_attrs)

      {:ok, sub} =
        Billing.create_manual_subscription(user, plan, %{
          status: "active",
          starts_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      canceled = Billing.cancel_subscription!(sub)
      assert canceled.status == "canceled"
      assert canceled.canceled_at != nil
    end
  end

  describe "admin_stats/0" do
    test "returns stats map" do
      stats = Billing.admin_stats()
      assert is_map(stats)
      assert Map.has_key?(stats, :total_users)
      assert Map.has_key?(stats, :active_subscriptions)
      assert Map.has_key?(stats, :active_plans)
      assert Map.has_key?(stats, :monthly_revenue_cents)
    end
  end

  describe "list_subscriptions/1" do
    test "filters by user_id" do
      user = user_fixture()
      {:ok, plan} = Billing.create_plan(@valid_plan_attrs)

      {:ok, _sub} =
        Billing.create_manual_subscription(user, plan, %{
          status: "active",
          starts_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      subs = Billing.list_subscriptions(user_id: user.id)
      assert length(subs) == 1
      assert hd(subs).user_id == user.id
    end
  end
end
