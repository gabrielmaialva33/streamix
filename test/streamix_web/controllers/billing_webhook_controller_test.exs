defmodule StreamixWeb.BillingWebhookControllerTest do
  use StreamixWeb.ConnCase, async: false

  alias Streamix.Billing

  import Streamix.AccountsFixtures

  setup do
    original = Application.get_env(:streamix, :stripe)

    Application.put_env(:streamix, :stripe, webhook_secret: "whsec_controller_test")

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:streamix, :stripe)
        config -> Application.put_env(:streamix, :stripe, config)
      end
    end)

    user = user_fixture()

    plan =
      Billing.ensure_plan!(%{
        name: "Webhook Premium",
        slug: "webhook-premium-test",
        description: "Webhook",
        price_cents: 1_999,
        currency: "BRL",
        billing_interval: "month",
        active: true,
        grants_global_access: false,
        features: %{global_catalog: true}
      })

    %{user: user, plan: plan}
  end

  test "accepts signed Stripe webhooks using the cached raw body", %{
    conn: conn,
    user: user,
    plan: plan
  } do
    raw_body =
      Phoenix.json_library().encode!(%{
        "id" => "evt_controller_test",
        "type" => "checkout.session.completed",
        "created" => 1_800_000_010,
        "data" => %{
          "object" => %{
            "id" => "cs_controller_test",
            "payment_status" => "paid",
            "amount_total" => 1_999,
            "currency" => "brl",
            "subscription" => "sub_controller_test",
            "metadata" => %{
              "user_id" => to_string(user.id),
              "plan_id" => to_string(plan.id)
            }
          }
        }
      })

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", stripe_signature(raw_body))
      |> post(~p"/api/billing/webhooks/stripe", raw_body)

    assert %{"received" => true} = json_response(conn, 200)
    assert Billing.entitled?(user, :global_catalog)
  end

  test "rejects unsigned Stripe webhooks", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/billing/webhooks/stripe", ~s({"type":"checkout.session.completed"}))

    assert %{"error" => %{"code" => "invalid_signature"}} = json_response(conn, 400)
  end

  defp stripe_signature(raw_body) do
    timestamp = System.system_time(:second)

    signature =
      :hmac
      |> :crypto.mac(:sha256, "whsec_controller_test", "#{timestamp}.#{raw_body}")
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{signature}"
  end
end
