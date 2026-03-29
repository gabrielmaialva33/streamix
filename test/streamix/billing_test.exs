defmodule Streamix.BillingTest do
  use Streamix.DataCase, async: true

  alias Streamix.AccountsFixtures
  alias Streamix.Billing
  alias Streamix.Billing.{Plan, Subscription}

  defp user_fixture(attrs \\ %{}) do
    AccountsFixtures.user_fixture(attrs)
  end

  defp plan_fixture(attrs \\ %{}) do
    params =
      Enum.into(attrs, %{
        name: "Pro",
        slug: "pro",
        description: "Access to all content",
        price_cents: 1_999,
        currency: "USD",
        billing_interval: "month",
        active: true,
        grants_global_access: true
      })

    %Plan{}
    |> Plan.changeset(params)
    |> Repo.insert!()
  end

  defp create_subscription!(user, plan, attrs) do
    params =
      Enum.into(attrs, %{
        status: "active",
        starts_at: DateTime.utc_now(),
        expires_at: nil,
        canceled_at: nil,
        source: "stripe",
        external_reference: "sub_123"
      })

    %Subscription{}
    |> Subscription.create_changeset(user, plan, params)
    |> Repo.insert!()
  end

  test "subscribed?/1 returns true only for active, non-expired subscriptions" do
    user = user_fixture()
    plan = plan_fixture()

    create_subscription!(user, plan,
      status: "active",
      expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
    )

    assert Billing.subscribed?(user)
  end

  test "expired subscriptions do not grant access" do
    user = user_fixture()
    plan = plan_fixture()

    create_subscription!(user, plan,
      status: "active",
      starts_at: DateTime.add(DateTime.utc_now(), -2, :day),
      expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
    )

    refute Billing.subscribed?(user)
  end

  test "non-active subscriptions do not grant access even when not expired" do
    user = user_fixture()
    plan = plan_fixture()

    create_subscription!(user, plan,
      status: "pending",
      expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
    )

    refute Billing.subscribed?(user)
  end

  test "future starts_at subscriptions do not grant access yet" do
    user = user_fixture()
    plan = plan_fixture()

    create_subscription!(user, plan,
      status: "active",
      starts_at: DateTime.add(DateTime.utc_now(), 1, :day),
      expires_at: DateTime.add(DateTime.utc_now(), 2, :day)
    )

    refute Billing.subscribed?(user)
    assert Billing.active_subscription_for_user(user) == nil
  end

  test "active_subscription_for_user/1 returns the latest active subscription with plan preloaded" do
    user = user_fixture()
    plan = plan_fixture()

    older_subscription =
      create_subscription!(user, plan,
        status: "active",
        starts_at: DateTime.add(DateTime.utc_now(), -2, :day),
        expires_at: DateTime.add(DateTime.utc_now(), 2, :day),
        external_reference: "sub_old"
      )

    newer_subscription =
      create_subscription!(user, plan,
        status: "active",
        starts_at: DateTime.add(DateTime.utc_now(), -1, :day),
        expires_at: DateTime.add(DateTime.utc_now(), 3, :day),
        external_reference: "sub_new"
      )

    assert %{id: subscription_id, plan: %Plan{id: plan_id}} =
             Billing.active_subscription_for_user(user)

    assert subscription_id == newer_subscription.id
    assert subscription_id != older_subscription.id
    assert plan_id == plan.id
  end

  test "plan changeset rejects negative prices" do
    changeset =
      Plan.changeset(%Plan{}, %{
        name: "Bad",
        slug: "bad",
        price_cents: -1,
        currency: "USD",
        billing_interval: "month"
      })

    assert %{price_cents: ["must be greater than or equal to 0"]} = errors_on(changeset)
  end

  test "subscription changeset rejects invalid statuses" do
    changeset = Subscription.changeset(%Subscription{}, %{status: "unknown"})

    assert %{status: ["is invalid"]} = errors_on(changeset)
  end

  test "subscription changeset rejects non-strict start and end ordering" do
    timestamp = DateTime.utc_now()

    changeset =
      Subscription.changeset(%Subscription{}, %{
        status: "active",
        starts_at: timestamp,
        expires_at: timestamp
      })

    assert %{expires_at: ["must be after starts_at"]} = errors_on(changeset)
  end

  test "create_changeset validates ownership and start/end ordering" do
    user = user_fixture()
    plan = plan_fixture()
    timestamp = DateTime.utc_now()

    changeset =
      Subscription.create_changeset(%Subscription{}, user, plan, %{
        status: "active",
        starts_at: timestamp,
        expires_at: timestamp,
        user_id: -1,
        plan_id: -1
      })

    assert Ecto.Changeset.get_field(changeset, :user_id) == user.id
    assert Ecto.Changeset.get_field(changeset, :plan_id) == plan.id
    assert %{expires_at: ["must be after starts_at"]} = errors_on(changeset)
  end

  test "inactive plans do not grant entitlement" do
    user = user_fixture()
    plan = plan_fixture(active: false)

    create_subscription!(user, plan,
      status: "active",
      starts_at: DateTime.add(DateTime.utc_now(), -1, :day),
      expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
    )

    refute Billing.subscribed?(user)
    assert Billing.active_subscription_for_user(user) == nil
  end

  test "plans without global access do not grant entitlement" do
    user = user_fixture()
    plan = plan_fixture(grants_global_access: false)

    create_subscription!(user, plan,
      status: "active",
      starts_at: DateTime.add(DateTime.utc_now(), -1, :day),
      expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
    )

    refute Billing.subscribed?(user)
    assert Billing.active_subscription_for_user(user) == nil
  end

  test "ensure_plan!/1 updates an existing plan without duplicating it" do
    attrs = %{
      name: "Premium Mensal",
      slug: "premium-monthly",
      description: "Plano premium com acesso global",
      price_cents: 1_999,
      currency: "USD",
      billing_interval: "month",
      active: true,
      grants_global_access: true
    }

    first_plan = Billing.ensure_plan!(attrs)

    updated_plan =
      Billing.ensure_plan!(Map.put(attrs, :description, "Updated global access plan"))

    assert first_plan.id == updated_plan.id
    assert updated_plan.description == "Updated global access plan"
    assert Repo.aggregate(from(p in Plan, where: p.slug == ^attrs.slug), :count, :id) == 1
  end

  test "ensure_manual_subscription!/3 reuses the same manual subscription" do
    user = user_fixture()

    plan =
      Billing.ensure_plan!(%{
        name: "Premium Mensal",
        slug: "premium-monthly",
        description: "Plano premium com acesso global",
        price_cents: 1_999,
        currency: "USD",
        billing_interval: "month",
        active: true,
        grants_global_access: true
      })

    starts_at = DateTime.utc_now() |> DateTime.truncate(:second)
    first_expires_at = DateTime.add(starts_at, 30, :day)
    second_expires_at = DateTime.add(starts_at, 60, :day)

    first_subscription =
      Billing.ensure_manual_subscription!(user, plan, %{
        status: "active",
        source: "manual",
        external_reference: "seed:#{user.email}:#{plan.slug}",
        starts_at: starts_at,
        expires_at: first_expires_at
      })

    second_subscription =
      Billing.ensure_manual_subscription!(user, plan, %{
        status: "active",
        source: "manual",
        external_reference: "seed:#{user.email}:#{plan.slug}",
        starts_at: starts_at,
        expires_at: second_expires_at
      })

    assert first_subscription.id == second_subscription.id
    assert second_subscription.expires_at == second_expires_at

    assert Repo.aggregate(
             from(s in Subscription,
               where: s.user_id == ^user.id and s.plan_id == ^plan.id and s.source == "manual"
             ),
             :count,
             :id
           ) == 1
  end
end
