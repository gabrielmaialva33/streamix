defmodule Streamix.BillingTest do
  use Streamix.DataCase, async: true

  alias Streamix.AccountsFixtures
  alias Streamix.Billing

  alias Streamix.Billing.{
    BillingCustomer,
    CheckoutSession,
    Invoice,
    Payment,
    Plan,
    PlanFeature,
    PlaybackSession,
    Subscription
  }

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
    assert Billing.subscribed?(%{id: user.id})
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

  test "account-linked schemas keep foreign keys without cross-context associations" do
    for schema <- [
          BillingCustomer,
          CheckoutSession,
          Invoice,
          Payment,
          PlaybackSession,
          Subscription
        ] do
      assert schema.__schema__(:type, :user_id) == :id
      refute :user in schema.__schema__(:associations)
    end

    for schema <- [Invoice, Payment, Subscription] do
      assert :user_email in schema.__schema__(:virtual_fields)
    end
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

  test "plan features can grant global catalog without the legacy plan flag" do
    user = user_fixture()
    plan = plan_fixture(grants_global_access: false)
    Billing.sync_plan_features!(plan, %{global_catalog: true})

    create_subscription!(user, plan,
      status: "active",
      starts_at: DateTime.add(DateTime.utc_now(), -1, :day),
      expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
    )

    assert Billing.entitled?(user, :global_catalog)
    assert Billing.subscribed?(user)

    assert %Subscription{plan: %Plan{features: [%PlanFeature{feature: "global_catalog"}]}} =
             Billing.active_subscription_for_user(user)
  end

  test "feature_limit_for/2 returns the active plan limit" do
    user = user_fixture()
    plan = plan_fixture()
    Billing.sync_plan_features!(plan, %{max_providers: 3, concurrent_streams: 2})

    create_subscription!(user, plan,
      status: "active",
      starts_at: DateTime.add(DateTime.utc_now(), -1, :day),
      expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
    )

    assert Billing.feature_limit_for(user, :max_providers) == 3
    assert Billing.feature_limit_for(user, "concurrent_streams") == 2
    assert Billing.feature_limit_for(user, :watch_party) == nil
  end

  test "start_playback_session/2 enforces concurrent stream limits" do
    user = user_fixture()
    plan = plan_fixture(grants_global_access: false)
    Billing.sync_plan_features!(plan, %{concurrent_streams: 1})

    Billing.ensure_manual_subscription!(user, plan, %{
      status: "active",
      external_reference: "test:screen-limit",
      starts_at: DateTime.utc_now(:second)
    })

    assert {:ok, session} =
             Billing.start_playback_session(user, %{
               content_type: "movie",
               content_id: 1
             })

    assert {:error, :concurrent_stream_limit_reached} =
             Billing.start_playback_session(user, %{
               content_type: "movie",
               content_id: 2
             })

    assert :ok = Billing.end_playback_session(session)

    assert {:ok, _session} =
             Billing.start_playback_session(user, %{
               content_type: "movie",
               content_id: 2
             })
  end

  test "start_playback_session/2 lets the same client supersede its own active session" do
    user = user_fixture()
    plan = plan_fixture(grants_global_access: false)
    Billing.sync_plan_features!(plan, %{concurrent_streams: 1})

    Billing.ensure_manual_subscription!(user, plan, %{
      status: "active",
      external_reference: "test:screen-limit-client",
      starts_at: DateTime.utc_now(:second)
    })

    attrs = %{content_type: "live_channel", content_id: 7, client_id: "tab-a"}

    assert {:ok, first} = Billing.start_playback_session(user, attrs)
    assert {:ok, second} = Billing.start_playback_session(user, %{attrs | content_id: 8})

    assert Repo.reload!(first).status == "ended"
    assert second.status == "active"
    assert second.client_id == "tab-a"
    assert Billing.active_playback_count(user) == 1

    assert {:error, :concurrent_stream_limit_reached} =
             Billing.start_playback_session(user, %{attrs | client_id: "tab-b"})

    assert {:error, :concurrent_stream_limit_reached} =
             Billing.start_playback_session(user, Map.delete(attrs, :client_id))
  end

  test "start_playback_session/2 ignores blank or oversized client ids" do
    user = user_fixture()

    assert {:ok, blank} =
             Billing.start_playback_session(user, %{
               content_type: "movie",
               content_id: 1,
               client_id: "   "
             })

    assert is_nil(blank.client_id)

    assert {:ok, oversized} =
             Billing.start_playback_session(user, %{
               content_type: "movie",
               content_id: 2,
               client_id: String.duplicate("x", 65)
             })

    assert is_nil(oversized.client_id)
  end

  test "end_playback_session/1 is idempotent when the session no longer exists" do
    user = user_fixture()

    assert {:ok, session} =
             Billing.start_playback_session(user, %{
               content_type: "movie",
               content_id: 1
             })

    Repo.delete!(session)

    assert :ok = Billing.end_playback_session(session)
  end

  test "start_trial_subscription/2 creates a one-time expiring trial" do
    user = user_fixture()
    plan = plan_fixture(price_cents: 0, trial_days: 7, grants_global_access: true)

    assert {:ok, subscription} = Billing.start_trial_subscription(user, plan)

    assert subscription.source == "trial"
    assert subscription.expires_at != nil
    assert DateTime.diff(subscription.expires_at, subscription.starts_at, :day) == 7
    assert Billing.subscribed?(user)

    assert {:error, :trial_already_used} = Billing.start_trial_subscription(user, plan)
  end

  test "create_checkout_session/3 stores self-service checkout state" do
    user = user_fixture()
    plan = plan_fixture()

    assert {:ok, %CheckoutSession{} = session} =
             Billing.create_checkout_session(user, plan, %{
               provider: "stripe",
               status: "open",
               external_id: "cs_test_123",
               checkout_url: "https://checkout.stripe.com/c/pay/cs_test_123",
               success_url: "https://streamix.test/plans/success",
               cancel_url: "https://streamix.test/plans"
             })

    assert session.user_id == user.id
    assert session.plan_id == plan.id
    assert session.amount_cents == plan.price_cents
    assert session.currency == plan.currency
  end

  test "activate_subscription_from_payment!/3 records payment, invoice, and entitlement" do
    user = user_fixture()
    plan = plan_fixture(grants_global_access: false)
    Billing.sync_plan_features!(plan, %{global_catalog: true})

    result =
      Billing.activate_subscription_from_payment!(user, plan, %{
        provider: "stripe",
        external_id: "pi_test_123",
        invoice_external_id: "in_test_123",
        invoice_number: "S-0001",
        amount_cents: plan.price_cents,
        currency: plan.currency,
        raw_event: %{"type" => "checkout.session.completed"}
      })

    assert %Subscription{status: "active"} = result.subscription
    assert %Payment{status: "paid", external_id: "pi_test_123"} = result.payment
    assert %Invoice{status: "paid", external_id: "in_test_123"} = result.invoice
    assert Billing.entitled?(user, :global_catalog)

    assert [%Payment{user_email: user_email}] = Billing.list_recent_payments(1)
    assert user_email == user.email

    assert [%Invoice{user_email: user_email}] = Billing.list_recent_invoices(1)
    assert user_email == user.email

    assert %Subscription{user_email: user_email} =
             Billing.list_subscriptions(user_id: user.id)
             |> Enum.find(&(&1.id == result.subscription.id))

    assert user_email == user.email

    again =
      Billing.activate_subscription_from_payment!(user, plan, %{
        provider: "stripe",
        external_id: "pi_test_123",
        invoice_external_id: "in_test_123",
        amount_cents: plan.price_cents,
        currency: plan.currency
      })

    assert again.payment.id == result.payment.id
    assert again.invoice.id == result.invoice.id
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
      grants_global_access: true,
      features: %{
        global_catalog: true,
        max_providers: 3,
        watch_party: true
      }
    }

    first_plan = Billing.ensure_plan!(attrs)

    updated_plan =
      Billing.ensure_plan!(Map.put(attrs, :description, "Updated global access plan"))

    assert first_plan.id == updated_plan.id
    assert updated_plan.description == "Updated global access plan"
    assert Repo.aggregate(from(p in Plan, where: p.slug == ^attrs.slug), :count, :id) == 1

    assert Repo.aggregate(from(f in PlanFeature, where: f.plan_id == ^first_plan.id), :count, :id) ==
             3
  end

  test "ensure_manual_subscription!/3 preserves the existing starts_at on rerun" do
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

    first_starts_at = DateTime.utc_now(:second)
    second_starts_at = DateTime.add(first_starts_at, 1, :day)
    first_expires_at = DateTime.add(first_starts_at, 30, :day)
    second_expires_at = DateTime.add(second_starts_at, 60, :day)

    first_subscription =
      Billing.ensure_manual_subscription!(user, plan, %{
        status: "active",
        source: "manual",
        external_reference: "seed:#{user.email}:#{plan.slug}",
        starts_at: first_starts_at,
        expires_at: first_expires_at
      })

    second_subscription =
      Billing.ensure_manual_subscription!(user, plan, %{
        status: "active",
        source: "manual",
        external_reference: "seed:#{user.email}:#{plan.slug}",
        starts_at: second_starts_at,
        expires_at: second_expires_at
      })

    assert first_subscription.id == second_subscription.id
    assert second_subscription.starts_at == first_starts_at
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
