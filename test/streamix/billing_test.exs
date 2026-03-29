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
    |> Subscription.changeset(params)
    |> Ecto.Changeset.put_change(:user_id, user.id)
    |> Ecto.Changeset.put_change(:plan_id, plan.id)
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

    subscription =
      create_subscription!(user, plan,
        status: "active",
        starts_at: DateTime.add(DateTime.utc_now(), -1, :day),
        expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
      )

    assert %{id: subscription_id, plan: %Plan{id: plan_id}} =
             Billing.active_subscription_for_user(user)

    assert subscription_id == subscription.id
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
end
