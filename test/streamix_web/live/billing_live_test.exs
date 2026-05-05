defmodule StreamixWeb.BillingLiveTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Streamix.Billing

  describe "billing portal" do
    setup :register_and_log_in_user

    test "renders current billing state", %{conn: conn, user: user} do
      plan =
        Billing.ensure_plan!(%{
          name: "Billing Premium",
          slug: "billing-premium",
          description: "Billing",
          price_cents: 1_999,
          currency: "BRL",
          billing_interval: "month",
          active: true,
          grants_global_access: false,
          features: %{global_catalog: true, concurrent_streams: 2}
        })

      Billing.ensure_manual_subscription!(user, plan, %{
        status: "active",
        external_reference: "test:billing-live",
        starts_at: DateTime.utc_now(:second)
      })

      {:ok, view, html} = live(conn, ~p"/billing")

      assert html =~ "Billing Premium"
      assert has_element?(view, "#billing-page")
      assert render(view) =~ "0 / 2"
    end
  end
end
