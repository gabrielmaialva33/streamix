defmodule Streamix.Billing.Admin do
  @moduledoc """
  Billing dashboard aggregates.
  """

  import Ecto.Query, warn: false

  alias Streamix.Accounts
  alias Streamix.Billing.{BillingCustomer, Invoice, Payment, Plan, Subscription}
  alias Streamix.Repo

  def admin_stats do
    now = DateTime.utc_now()

    %{
      total_users: Accounts.count_users(),
      active_subscriptions:
        from(s in Subscription, where: s.status == "active")
        |> Repo.aggregate(:count),
      active_plans:
        from(p in Plan, where: p.active == true)
        |> Repo.aggregate(:count),
      monthly_revenue_cents:
        from(s in Subscription,
          join: p in assoc(s, :plan),
          where: s.status == "active",
          where: is_nil(s.expires_at) or s.expires_at > ^now,
          select: coalesce(sum(p.price_cents), 0)
        )
        |> Repo.one(),
      failed_payments:
        from(p in Payment, where: p.status == "failed")
        |> Repo.aggregate(:count),
      paid_invoices:
        from(i in Invoice, where: i.status == "paid")
        |> Repo.aggregate(:count),
      billing_customers:
        from(c in BillingCustomer)
        |> Repo.aggregate(:count)
    }
  end
end
