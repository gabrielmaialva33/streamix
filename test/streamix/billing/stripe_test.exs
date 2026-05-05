defmodule Streamix.Billing.StripeTest do
  use Streamix.DataCase, async: false

  alias Streamix.Billing
  alias Streamix.Billing.{CheckoutSession, Payment, Stripe, Subscription}
  alias Streamix.Repo

  import Streamix.AccountsFixtures

  defmodule FakeStripeClient do
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
      checkout_sessions_url: "https://api.stripe.test/v1/checkout/sessions"
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

    assert subscription.external_reference == "stripe:sub_test_123"
    assert Billing.entitled?(user, :global_catalog)
    assert Repo.get_by!(Payment, provider: "stripe", external_id: "cs_test_completed")

    assert {:ok, %{subscription: %Subscription{} = replayed_subscription}} =
             Stripe.handle_webhook(raw_body, signature)

    assert replayed_subscription.id == subscription.id

    assert Repo.aggregate(Payment, :count) == 1
  end

  test "paid checkout cancels the previous active user plan", %{user: user, plan: new_plan} do
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
    assert Repo.reload!(old_subscription).status == "canceled"
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

  defp stripe_signature(raw_body) do
    timestamp = System.system_time(:second)

    signature =
      :hmac
      |> :crypto.mac(:sha256, "whsec_test_123", "#{timestamp}.#{raw_body}")
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{signature}"
  end
end
