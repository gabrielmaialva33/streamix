defmodule Streamix.Billing.StripeTest do
  use Streamix.DataCase, async: false

  alias Streamix.Billing
  alias Streamix.Billing.{CheckoutSession, Invoice, Payment, Stripe, Subscription}
  alias Streamix.Repo
  alias Streamix.Workers.ReconcileStripeSubscriptionsWorker

  import Streamix.AccountsFixtures

  defmodule FakeStripeClient do
    def get(url, opts) do
      customer =
        url
        |> URI.parse()
        |> Map.get(:query)
        |> then(&URI.decode_query(&1 || ""))
        |> Map.get("customer")

      case if(customer == "cus_failure", do: :timeout, else: Process.get(:stripe_get_error)) do
        nil -> get_success(url, opts)
        reason -> {:error, reason}
      end
    end

    defp get_success("https://api.stripe.test/v1/subscriptions/" <> id = url, opts) do
      send(self(), {:stripe_get, url, opts})
      now = DateTime.to_unix(DateTime.utc_now(:second))
      {user, plan} = Process.get(:stripe_subject)

      {:ok,
       %Req.Response{
         status: 200,
         body:
           Map.merge(
             %{
               "id" => id,
               "object" => "subscription",
               "status" => Process.get(:stripe_subscription_status, "active"),
               "customer" =>
                 if(id == "sub_reconcile_123", do: "cus_reconcile_test", else: "cus_test_123"),
               "latest_invoice" => %{"id" => "in_current", "status" => "paid", "paid" => true},
               "current_period_start" => now - 60,
               "current_period_end" => now + 2_592_000,
               "metadata" => %{
                 "user_id" => user.id,
                 "plan_id" => Process.get(:stripe_plan_id, plan.id)
               }
             },
             Process.get(:stripe_subscription_overrides, %{})
           )
       }}
    end

    defp get_success(url, opts) do
      send(self(), {:stripe_get, url, opts})

      price_id = Process.get(:stripe_reconcile_price_id, "price_reconcile_test")
      now = DateTime.utc_now(:second) |> DateTime.to_unix()

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "data" => [
             %{
               "id" => "sub_reconcile_123",
               "object" => "subscription",
               "status" => "active",
               "customer" => "cus_reconcile_test",
               "current_period_start" => now,
               "current_period_end" => now + 2_592_000,
               "metadata" => %{},
               "items" => %{
                 "data" => [
                   %{"price" => %{"id" => price_id}}
                 ]
               }
             }
           ]
         }
       }}
    end

    def post("https://api.stripe.test/v1/billing_portal/sessions" = url, opts) do
      send(self(), {:stripe_portal_post, url, opts})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"id" => "bps_test_123", "url" => "https://billing.stripe.com/p/session"}
       }}
    end

    def post(url, opts) do
      send(self(), {:stripe_post, url, opts})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "id" => "cs_test_123",
           "status" => "open",
           "url" => "https://checkout.stripe.com/c/test_123",
           "expires_at" => 1_800_000_000,
           "metadata" => %{}
         }
       }}
    end
  end

  setup do
    original = Application.get_env(:streamix, :stripe)

    Application.put_env(:streamix, :stripe,
      secret_key: "sk_test_123",
      webhook_secret: "whsec_test_123",
      http_client: FakeStripeClient,
      checkout_sessions_url: "https://api.stripe.test/v1/checkout/sessions",
      billing_portal_sessions_url: "https://api.stripe.test/v1/billing_portal/sessions",
      subscriptions_url: "https://api.stripe.test/v1/subscriptions"
    )

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:streamix, :stripe)
        config -> Application.put_env(:streamix, :stripe, config)
      end
    end)

    user = user_fixture()

    plan =
      Billing.ensure_plan!(%{
        name: "Premium",
        slug: "premium-stripe-test",
        description: "Premium Stripe",
        price_cents: 1_999,
        currency: "BRL",
        billing_interval: "month",
        active: true,
        grants_global_access: false,
        features: %{global_catalog: true}
      })

    Process.put(:stripe_subject, {user, plan})
    %{user: user, plan: plan}
  end

  test "create_checkout_session/3 creates a hosted Stripe subscription checkout", %{
    user: user,
    plan: plan
  } do
    assert {:ok, %CheckoutSession{} = session} =
             Stripe.create_checkout_session(user, plan, %{
               success_url: "https://streamix.test/plans?checkout=success",
               cancel_url: "https://streamix.test/plans?checkout=canceled"
             })

    assert session.provider == "stripe"
    assert session.status == "open"
    assert session.external_id == "cs_test_123"
    assert session.checkout_url == "https://checkout.stripe.com/c/test_123"

    assert_received {:stripe_post, "https://api.stripe.test/v1/checkout/sessions", opts}

    assert {"authorization", "Bearer sk_test_123"} in opts[:headers]
    assert URI.decode_query(opts[:body])["mode"] == "subscription"

    assert URI.decode_query(opts[:body])["line_items[0][price_data][recurring][interval]"] ==
             "month"

    assert URI.decode_query(opts[:body])["subscription_data[metadata][plan_id]"] ==
             to_string(plan.id)

    assert URI.decode_query(opts[:body])["metadata[user_id]"] == to_string(user.id)
  end

  test "create_checkout_session/3 uses Stripe price ID when plan has one", %{
    user: user,
    plan: plan
  } do
    {:ok, plan} = Billing.update_plan(plan, %{stripe_price_id: "price_test_123", trial_days: 7})

    assert {:ok, %CheckoutSession{}} =
             Stripe.create_checkout_session(user, plan, %{
               success_url: "https://streamix.test/plans?checkout=success",
               cancel_url: "https://streamix.test/plans?checkout=canceled"
             })

    assert_received {:stripe_post, "https://api.stripe.test/v1/checkout/sessions", opts}

    body = URI.decode_query(opts[:body])
    assert body["line_items[0][price]"] == "price_test_123"
    assert body["subscription_data[trial_period_days]"] == "7"
    refute Map.has_key?(body, "line_items[0][price_data][unit_amount]")
  end

  test "handle_webhook/2 activates plan and stores payment history idempotently", %{
    user: user,
    plan: plan
  } do
    event = %{
      "id" => "evt_test_123",
      "type" => "checkout.session.completed",
      "created" => 1_800_000_010,
      "data" => %{
        "object" => %{
          "id" => "cs_test_completed",
          "object" => "checkout.session",
          "payment_status" => "paid",
          "amount_total" => 1_999,
          "currency" => "brl",
          "customer" => "cus_test_123",
          "subscription" => "sub_test_123",
          "invoice" => "in_test_123",
          "metadata" => %{
            "user_id" => to_string(user.id),
            "plan_id" => to_string(plan.id)
          }
        }
      }
    }

    raw_body = Phoenix.json_library().encode!(event)
    signature = stripe_signature(raw_body)

    assert {:ok, %{subscription: %Subscription{} = subscription}} =
             Stripe.handle_webhook(raw_body, signature)

    assert_received {:stripe_get, "https://api.stripe.test/v1/subscriptions/sub_test_123",
                     fetch_opts}

    assert fetch_opts[:params] == [{"expand[]", "latest_invoice"}]
    assert subscription.external_reference == "stripe:sub_test_123"
    assert Billing.get_billing_customer(user, :stripe).external_id == "cus_test_123"
    assert Billing.entitled?(user, :global_catalog)
    assert Repo.get_by!(Payment, provider: "stripe", external_id: "cs_test_completed")

    assert {:ok, :duplicate} = Stripe.handle_webhook(raw_body, signature)

    assert Repo.aggregate(Payment, :count) == 1
  end

  test "create_portal_session/2 opens Stripe customer portal", %{user: user} do
    Billing.upsert_billing_customer!(user, :stripe, "cus_portal_test")

    assert {:ok, "https://billing.stripe.com/p/session"} =
             Stripe.create_portal_session(user, "https://streamix.test/billing")

    assert_received {:stripe_portal_post, "https://api.stripe.test/v1/billing_portal/sessions",
                     opts}

    assert URI.decode_query(opts[:body])["customer"] == "cus_portal_test"
    assert URI.decode_query(opts[:body])["return_url"] == "https://streamix.test/billing"
  end

  test "subscription update webhook synchronizes plan status without creating payment", %{
    user: user,
    plan: plan
  } do
    event = %{
      "id" => "evt_sub_updated",
      "type" => "customer.subscription.updated",
      "data" => %{
        "object" => %{
          "id" => "sub_updated_123",
          "object" => "subscription",
          "status" => "active",
          "customer" => "cus_updated_123",
          "current_period_start" => 1_800_000_000,
          "current_period_end" => 1_802_592_000,
          "metadata" => %{
            "user_id" => to_string(user.id),
            "plan_id" => to_string(plan.id)
          }
        }
      }
    }

    raw_body = Phoenix.json_library().encode!(event)

    assert {:ok, %{subscription: subscription}} =
             Stripe.handle_webhook(raw_body, stripe_signature(raw_body))

    assert subscription.external_reference == "stripe:sub_updated_123"
    assert subscription.status == "active"
    assert Repo.aggregate(Payment, :count) == 0
  end

  test "reconcile_subscriptions/0 syncs Stripe subscriptions by local customer and price ID", %{
    user: user,
    plan: plan
  } do
    price_id = "price_reconcile_test_#{plan.id}"
    Process.put(:stripe_reconcile_price_id, price_id)

    {:ok, _plan} = Billing.update_plan(plan, %{stripe_price_id: price_id})
    Billing.upsert_billing_customer!(user, :stripe, "cus_reconcile_test")

    assert {:ok, %{customers: 1, results: [%{synced: [{:ok, %{subscription: subscription}}]}]}} =
             Stripe.reconcile_subscriptions()

    assert_received {:stripe_get, "https://api.stripe.test/v1/subscriptions?" <> query, opts}
    assert query =~ "customer=cus_reconcile_test"
    assert query =~ "status=all"
    assert {"authorization", "Bearer sk_test_123"} in opts[:headers]

    assert subscription.external_reference == "stripe:sub_reconcile_123"

    assert Billing.active_subscription_for_user(user).external_reference ==
             subscription.external_reference
  end

  test "paid checkout preserves an administrator-granted plan", %{user: user, plan: new_plan} do
    old_plan =
      Billing.ensure_plan!(%{
        name: "Old Premium",
        slug: "old-premium-stripe-test",
        description: "Old",
        price_cents: 999,
        currency: "BRL",
        billing_interval: "month",
        active: true,
        grants_global_access: true
      })

    old_subscription =
      Billing.ensure_manual_subscription!(user, old_plan, %{
        status: "active",
        external_reference: "manual:old",
        starts_at: DateTime.utc_now(:second)
      })

    result =
      Billing.activate_subscription_from_payment!(user, new_plan, %{
        provider: "stripe",
        external_id: "cs_upgrade",
        subscription_external_reference: "stripe:sub_upgrade"
      })

    assert result.subscription.plan_id == new_plan.id
    assert Repo.reload!(old_subscription).status == "active"
  end

  test "handle_webhook/2 rejects invalid signatures", %{user: user, plan: plan} do
    raw_body =
      Phoenix.json_library().encode!(%{
        "type" => "checkout.session.completed",
        "data" => %{"object" => %{"metadata" => %{"user_id" => user.id, "plan_id" => plan.id}}}
      })

    assert {:error, :invalid_signature} =
             Stripe.handle_webhook(raw_body, "t=#{System.system_time(:second)},v1=bad")
  end

  test "unpaid checkout records pending payment without granting access or replacing a manual grant",
       %{user: user, plan: plan} do
    event = checkout_event(user, plan, "unpaid")
    assert {:ok, result} = Stripe.apply_event(event)
    assert result.payment.status == "pending"
    assert result.payment.paid_at == nil
    assert result.subscription.status == "pending"
    refute Billing.entitled?(user, :global_catalog)

    manual =
      Billing.ensure_manual_subscription!(user, plan, %{expires_at: ~U[2028-12-31 00:00:00Z]})

    assert {:ok, _} = Stripe.apply_event(event)
    assert Repo.reload!(manual).status == "active"
    assert Repo.reload!(manual).expires_at == ~U[2028-12-31 00:00:00Z]
  end

  test "async completion grants access and a late failure cannot undo paid payment", %{
    user: user,
    plan: plan
  } do
    assert {:ok, _} = Stripe.apply_event(checkout_event(user, plan, "unpaid"))

    paid =
      checkout_event(user, plan, "paid")
      |> Map.put("type", "checkout.session.async_payment_succeeded")

    assert {:ok, %{payment: payment, subscription: subscription}} = Stripe.apply_event(paid)
    assert payment.status == "paid"
    assert subscription.status == "active"

    failed =
      checkout_event(user, plan, "unpaid")
      |> Map.put("type", "checkout.session.async_payment_failed")

    Process.put(:stripe_subscription_status, "active")
    failed = Map.put(failed, "id", "evt_failed_late")
    assert {:ok, _} = Stripe.apply_event(failed)
    assert Repo.reload!(subscription).status == "active"
    assert Repo.reload!(payment).status == "paid"
  end

  test "no-payment-required checkout waits for an explicit trial subscription", %{
    user: user,
    plan: plan
  } do
    assert {:ok, %{subscription: pending}} =
             Stripe.apply_event(checkout_event(user, plan, "no_payment_required"))

    assert pending.status == "pending"
    refute Billing.entitled?(user, :global_catalog)

    object = %{
      "id" => "sub_pending_test",
      "object" => "subscription",
      "status" => "trialing",
      "metadata" => %{"user_id" => user.id, "plan_id" => plan.id}
    }

    Process.put(:stripe_subscription_status, "trialing")

    assert {:ok, %{subscription: trial}} =
             Stripe.apply_event(%{
               "id" => "evt_trial_updated",
               "type" => "customer.subscription.updated",
               "data" => %{"object" => object}
             })

    assert trial.status == "active"
    assert Billing.entitled?(user, :global_catalog)
  end

  test "cancellation cannot be undone by a replayed checkout or a distinct late paid event", %{
    user: user,
    plan: plan
  } do
    paid = checkout_event(user, plan, "paid")
    assert {:ok, %{subscription: subscription}} = Stripe.apply_event(paid)

    deleted = %{
      "id" => "evt_deleted",
      "type" => "customer.subscription.deleted",
      "data" => %{
        "object" => %{
          "id" => "sub_pending_test",
          "object" => "subscription",
          "status" => "canceled"
        }
      }
    }

    Process.put(:stripe_subscription_status, "canceled")
    assert {:ok, _} = Stripe.apply_event(deleted)
    assert {:ok, _} = Stripe.apply_event(paid)
    assert Repo.reload!(subscription).status == "canceled"
    late = paid |> Map.put("id", "evt_distinct_late_paid") |> Map.put("type", "invoice.paid")
    assert {:ok, _} = Stripe.apply_event(late)
    assert Repo.reload!(subscription).status == "canceled"
    refute Billing.entitled?(user, :global_catalog)
  end

  test "a failed authoritative fetch changes nothing and is retryable", %{user: user, plan: plan} do
    event = checkout_event(user, plan, "paid")
    Process.put(:stripe_get_error, :timeout)
    assert {:error, _} = Stripe.apply_event(event)
    refute Billing.entitled?(user, :global_catalog)
    assert Repo.aggregate(Payment, :count) == 0
    Process.delete(:stripe_get_error)
    assert {:ok, %{subscription: subscription}} = Stripe.apply_event(event)
    assert subscription.status == "active"
  end

  test "reconciliation propagates a per-customer upstream error", %{user: user} do
    Billing.upsert_billing_customer!(user, :stripe, "cus_failed")
    Process.put(:stripe_get_error, :timeout)
    assert {:error, %{customers: 1, failed: 1}} = Stripe.reconcile_subscriptions()
  end

  test "reconciliation propagates an unknown subscription subject and the worker retries", %{
    user: user
  } do
    Billing.upsert_billing_customer!(user, :stripe, "cus_reconcile_test")
    Process.put(:stripe_plan_id, 9_999_999)
    assert {:error, %{failed: 1}} = Stripe.reconcile_subscriptions()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:stripe_reconciliation_incomplete, 1}} =
                 ReconcileStripeSubscriptionsWorker.perform(%Oban.Job{})
      end)

    assert log =~ "Stripe reconciliation incomplete"
    refute log =~ "cus_reconcile_test"
    refute log =~ "unknown_billing_subject"
  end

  test "a distinct stale invoice failure uses the current paid subscription", %{
    user: user,
    plan: plan
  } do
    event = checkout_event(user, plan, "paid")
    assert {:ok, %{subscription: subscription}} = Stripe.apply_event(event)

    failed =
      event
      |> Map.put("id", "evt_old_invoice_failure")
      |> Map.put("type", "invoice.payment_failed")

    assert {:ok, _} = Stripe.apply_event(failed)
    assert Repo.reload!(subscription).status == "active"
  end

  test "active subscription without a bounded billing period is not granted", %{
    user: user,
    plan: plan
  } do
    event = checkout_event(user, plan, "paid")
    Process.put(:stripe_subscription_overrides, %{"current_period_end" => nil})
    assert {:error, :missing_billing_period} = Stripe.apply_event(event)
    refute Billing.entitled?(user, :global_catalog)
  end

  test "mixed reconciliation failures use all three Oban attempts", %{user: user} do
    Billing.upsert_billing_customer!(user, :stripe, "cus_reconcile_test")
    Billing.upsert_billing_customer!(user_fixture(), :stripe, "cus_failure")
    assert {:error, %{customers: 2, succeeded: 1, failed: 1}} = Stripe.reconcile_subscriptions()
    job = %{} |> ReconcileStripeSubscriptionsWorker.new() |> Oban.insert!()

    ExUnit.CaptureLog.capture_log(fn ->
      for attempt <- 1..3 do
        Oban.drain_queue(queue: :billing, with_scheduled: true)
        current = Repo.get!(Oban.Job, job.id)
        assert current.attempt == attempt
        assert current.state == if(attempt == 3, do: "discarded", else: "retryable")
      end
    end)
  end

  test "old checkout metadata cannot restore an old plan after an authoritative plan change", %{
    user: user,
    plan: plan
  } do
    event = checkout_event(user, plan, "paid")
    assert {:ok, %{subscription: subscription}} = Stripe.apply_event(event)

    replacement =
      Billing.ensure_plan!(%{
        name: "Replacement",
        slug: "replacement-order-test",
        price_cents: 2999,
        currency: "BRL",
        billing_interval: "month",
        active: true
      })

    Process.put(:stripe_plan_id, replacement.id)

    updated = %{
      "id" => "evt_new_plan",
      "type" => "customer.subscription.updated",
      "data" => %{"object" => %{"id" => "sub_pending_test", "object" => "subscription"}}
    }

    assert {:ok, _} = Stripe.apply_event(updated)
    assert {:ok, _} = Stripe.apply_event(Map.put(event, "id", "evt_old_plan_paid_late"))
    assert Repo.reload!(subscription).plan_id == replacement.id
    assert Repo.reload!(subscription).status == "active"
  end

  test "subscription-item periods bound access when top-level period fields are absent", %{
    user: user,
    plan: plan
  } do
    event = checkout_event(user, plan, "paid")
    now = DateTime.to_unix(DateTime.utc_now(:second))

    Process.put(:stripe_subscription_overrides, %{
      "current_period_start" => nil,
      "current_period_end" => nil,
      "items" => %{
        "data" => [%{"current_period_start" => now - 60, "current_period_end" => now + 3600}]
      }
    })

    assert {:ok, %{subscription: subscription}} = Stripe.apply_event(event)
    assert subscription.expires_at == DateTime.from_unix!(now + 3600)
    assert Billing.entitled?(user, :global_catalog)
  end

  test "an active subscription with an unpaid first invoice waits for confirmation", %{
    user: user,
    plan: plan
  } do
    unpaid = checkout_event(user, plan, "unpaid")
    Process.put(:stripe_subscription_status, "active")

    Process.put(:stripe_subscription_overrides, %{
      "latest_invoice" => %{"status" => "open", "paid" => false}
    })

    assert {:ok, %{subscription: subscription, payment: payment}} = Stripe.apply_event(unpaid)
    assert subscription.status == "pending"
    assert payment.status == "pending"
    refute Billing.entitled?(user, :global_catalog)
    Process.delete(:stripe_subscription_overrides)
    assert {:ok, _} = Stripe.apply_event(checkout_event(user, plan, "paid"))
    assert Billing.entitled?(user, :global_catalog)
    assert {:ok, _} = Stripe.apply_event(Map.put(unpaid, "id", "evt_unpaid_late_distinct"))
    assert Billing.entitled?(user, :global_catalog)
    assert Repo.reload!(payment).status == "paid"
  end

  test "async checkout without an invoice id does not invent two invoices", %{
    user: user,
    plan: plan
  } do
    assert {:ok, _} = Stripe.apply_event(checkout_event(user, plan, "unpaid"))

    paid =
      checkout_event(user, plan, "paid")
      |> Map.put("type", "checkout.session.async_payment_succeeded")

    assert {:ok, _} = Stripe.apply_event(paid)
    assert Repo.aggregate(Invoice, :count) == 0
  end

  test "a lower-detail checkout cannot erase an already received invoice", %{
    user: user,
    plan: plan
  } do
    checkout = checkout_event(user, plan, "paid")

    object =
      checkout["data"]["object"]
      |> Map.merge(%{
        "id" => "in_shared",
        "object" => "invoice",
        "status" => "paid",
        "number" => "N-42",
        "hosted_invoice_url" => "https://billing.example.test/invoice"
      })

    invoice_event = %{
      "id" => "evt_full_invoice",
      "type" => "invoice.paid",
      "data" => %{"object" => object}
    }

    assert {:ok, _} = Stripe.apply_event(invoice_event)
    checkout = put_in(checkout, ["data", "object", "invoice"], "in_shared")
    assert {:ok, _} = Stripe.apply_event(checkout)
    invoice = Repo.get_by!(Invoice, provider: "stripe", external_id: "in_shared")
    assert invoice.number == "N-42"
    assert invoice.hosted_invoice_url == "https://billing.example.test/invoice"
  end

  test "current mapped price wins over stale subscription metadata", %{user: user, plan: plan} do
    next =
      Billing.ensure_plan!(%{
        name: "New price",
        slug: "mapped-current-price",
        price_cents: 3999,
        currency: "BRL",
        billing_interval: "month",
        active: true,
        stripe_price_id: "price_current"
      })

    event = checkout_event(user, plan, "paid")

    Process.put(:stripe_subscription_overrides, %{
      "items" => %{"data" => [%{"price" => %{"id" => "price_current"}}]}
    })

    assert {:ok, %{subscription: subscription}} = Stripe.apply_event(event)
    assert subscription.plan_id == next.id
  end

  test "checkout reuses the mapped customer and an old customer event cannot replace it", %{
    user: user,
    plan: plan
  } do
    Billing.upsert_billing_customer!(user, :stripe, "cus_current")

    assert {:ok, _} =
             Stripe.create_checkout_session(user, plan, %{
               success_url: "https://example.test/ok",
               cancel_url: "https://example.test/cancel"
             })

    assert_received {:stripe_post, _, opts}
    body = URI.decode_query(opts[:body])
    assert body["customer"] == "cus_current"
    refute Map.has_key?(body, "customer_email")

    event =
      checkout_event(user, plan, "paid")
      |> put_in(["data", "object", "customer"], "cus_historical")

    Process.put(:stripe_subscription_overrides, %{"customer" => "cus_historical"})
    assert {:ok, _} = Stripe.apply_event(event)
    assert Billing.get_billing_customer(user, :stripe).external_id == "cus_current"
    # The current customer's list returns sub_reconcile_123, not this historical ref.
    assert {:ok, summary} = Stripe.reconcile_subscriptions()
    assert [%{synced: synced}] = summary.results
    references = Enum.map(synced, fn {:ok, %{subscription: sub}} -> sub.external_reference end)
    assert "stripe:sub_pending_test" in references
    assert Billing.get_billing_customer(user, :stripe).external_id == "cus_current"
  end

  defp checkout_event(user, plan, payment_status) do
    Process.put(
      :stripe_subscription_status,
      if(payment_status == "paid", do: "active", else: "incomplete")
    )

    %{
      "id" => "evt_pending_#{payment_status}",
      "type" => "checkout.session.completed",
      "created" => 1_800_000_000,
      "data" => %{
        "object" => %{
          "id" => "cs_pending_test",
          "object" => "checkout.session",
          "subscription" => "sub_pending_test",
          "payment_status" => payment_status,
          "metadata" => %{"user_id" => user.id, "plan_id" => plan.id}
        }
      }
    }
  end

  defp stripe_signature(raw_body) do
    timestamp = System.system_time(:second)

    signature =
      :hmac
      |> :crypto.mac(:sha256, "whsec_test_123", "#{timestamp}.#{raw_body}")
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{signature}"
  end
end
