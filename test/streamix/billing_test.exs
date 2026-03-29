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
    |> Ecto.Changeset.cast(params, [
      :name,
      :slug,
      :description,
      :price_cents,
      :currency,
      :billing_interval,
      :active,
      :grants_global_access
    ])
    |> Ecto.Changeset.validate_required([
      :name,
      :slug,
      :price_cents,
      :currency,
      :billing_interval,
      :active,
      :grants_global_access
    ])
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
    |> Ecto.Changeset.cast(params, [
      :status,
      :starts_at,
      :expires_at,
      :canceled_at,
      :source,
      :external_reference
    ])
    |> Ecto.Changeset.validate_required([:status])
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
end
