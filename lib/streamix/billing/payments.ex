defmodule Streamix.Billing.Payments do
  @moduledoc """
  Checkout sessions, payment records and invoices.
  """

  import Ecto.Query, warn: false

  alias Streamix.Accounts.User

  alias Streamix.Billing.{
    CheckoutSession,
    Invoice,
    Payment,
    Plan,
    Subscription,
    Subscriptions
  }

  alias Streamix.Repo

  def create_checkout_session(%User{} = user, %Plan{} = plan, attrs) do
    %CheckoutSession{}
    |> CheckoutSession.create_changeset(user, plan, Map.merge(%{status: "pending"}, attrs))
    |> Repo.insert()
  end

  def activate_subscription_from_payment!(%User{} = user, %Plan{} = plan, attrs)
      when is_map(attrs) do
    Repo.transaction(fn ->
      provider = Map.fetch!(attrs, :provider)
      external_id = Map.get(attrs, :external_id)
      now = DateTime.utc_now(:second)

      external_reference =
        Map.get(attrs, :subscription_external_reference) ||
          payment_subscription_reference(provider, external_id, user, plan)

      Subscriptions.cancel_other_active_subscriptions!(user.id, external_reference, now)

      subscription =
        Subscriptions.ensure_manual_subscription!(user, plan, %{
          status: "active",
          source: provider,
          external_reference: external_reference,
          starts_at: Map.get(attrs, :starts_at, now),
          expires_at: Map.get(attrs, :expires_at)
        })

      payment =
        upsert_payment!(user, plan, subscription, %{
          provider: provider,
          status: Map.get(attrs, :status, "paid"),
          external_id: external_id,
          amount_cents: Map.get(attrs, :amount_cents, plan.price_cents),
          currency: Map.get(attrs, :currency, plan.currency),
          paid_at: Map.get(attrs, :paid_at, now),
          failure_reason: Map.get(attrs, :failure_reason),
          raw_event: Map.get(attrs, :raw_event, %{})
        })

      invoice =
        maybe_upsert_invoice!(user, plan, subscription, attrs, now)

      %{subscription: subscription, payment: payment, invoice: invoice}
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> raise inspect(reason)
    end
  end

  def list_invoices(%User{id: user_id}) do
    from(i in Invoice,
      where: i.user_id == ^user_id,
      preload: [:plan, :subscription],
      order_by: [desc: i.inserted_at, desc: i.id]
    )
    |> Repo.all()
  end

  def list_payments(%User{id: user_id}) do
    from(p in Payment,
      where: p.user_id == ^user_id,
      preload: [:plan, :subscription],
      order_by: [desc: p.inserted_at, desc: p.id]
    )
    |> Repo.all()
  end

  def list_recent_payments(limit \\ 20) do
    from(p in Payment,
      preload: [:user, :plan, :subscription],
      order_by: [desc: p.inserted_at, desc: p.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  def list_recent_invoices(limit \\ 20) do
    from(i in Invoice,
      preload: [:user, :plan, :subscription],
      order_by: [desc: i.inserted_at, desc: i.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp payment_subscription_reference(provider, nil, %User{id: user_id}, %Plan{id: plan_id}) do
    "billing:#{provider}:#{user_id}:#{plan_id}"
  end

  defp payment_subscription_reference(provider, external_id, _user, _plan) do
    "billing:#{provider}:#{external_id}"
  end

  # The previous `get_by + insert/update` shape lost to Stripe retries —
  # two concurrent webhook deliveries with the same external_id both
  # observed `nil` from get_by and both tried to insert, with the second
  # blowing up on the partial unique index (which then made Stripe retry
  # the whole event yet again). The partial unique index on
  # (provider, external_id) where external_id IS NOT NULL is the right
  # idempotency key — let Postgres enforce it via ON CONFLICT.
  defp upsert_payment!(%User{} = user, %Plan{} = plan, %Subscription{} = subscription, attrs) do
    payment_attrs =
      attrs
      |> Map.put(:user_id, user.id)
      |> Map.put(:plan_id, plan.id)
      |> Map.put(:subscription_id, subscription.id)

    if blank_external_id?(payment_attrs) do
      # No external id → can't dedupe via the unique index. Keep the
      # legacy fallback path (first webhook delivery without IDs is
      # unusual but possible in dev / manual entries).
      %Payment{}
      |> Payment.changeset(payment_attrs)
      |> Repo.insert!()
    else
      # Partial unique index is `(provider, external_id) WHERE external_id
      # IS NOT NULL` — Postgres needs the predicate spelled out in the
      # conflict target to match it (the column-only form fails with
      # 42P10 because plain `(provider, external_id)` doesn't equal the
      # partial index). The unsafe_fragment is the documented Ecto
      # escape hatch for this exact case.
      %Payment{}
      |> Payment.changeset(payment_attrs)
      |> Repo.insert!(
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target:
          {:unsafe_fragment, "(provider, external_id) WHERE external_id IS NOT NULL"}
      )
    end
  end

  defp blank_external_id?(%{external_id: id}) when is_binary(id) and byte_size(id) > 0, do: false
  defp blank_external_id?(_), do: true

  defp maybe_upsert_invoice!(
         %User{} = user,
         %Plan{} = plan,
         %Subscription{} = subscription,
         attrs,
         now
       ) do
    invoice_attrs = Map.get(attrs, :invoice, %{})

    invoice_attrs =
      %{
        user_id: user.id,
        plan_id: plan.id,
        subscription_id: subscription.id,
        provider: Map.fetch!(attrs, :provider),
        status: Map.get(invoice_attrs, :status, Map.get(attrs, :invoice_status, "paid")),
        external_id: Map.get(invoice_attrs, :external_id, Map.get(attrs, :invoice_external_id)),
        number: Map.get(invoice_attrs, :number, Map.get(attrs, :invoice_number)),
        amount_due_cents:
          Map.get(
            invoice_attrs,
            :amount_due_cents,
            Map.get(attrs, :amount_cents, plan.price_cents)
          ),
        amount_paid_cents:
          Map.get(
            invoice_attrs,
            :amount_paid_cents,
            Map.get(attrs, :amount_cents, plan.price_cents)
          ),
        currency: Map.get(invoice_attrs, :currency, Map.get(attrs, :currency, plan.currency)),
        hosted_invoice_url:
          Map.get(invoice_attrs, :hosted_invoice_url, Map.get(attrs, :hosted_invoice_url)),
        due_at: Map.get(invoice_attrs, :due_at, Map.get(attrs, :invoice_due_at)),
        paid_at: Map.get(invoice_attrs, :paid_at, Map.get(attrs, :paid_at, now)),
        metadata: Map.get(invoice_attrs, :metadata, %{})
      }

    # Same idempotency story as payments — partial unique index on
    # (provider, external_id) where external_id IS NOT NULL needs its
    # predicate echoed in the conflict_target via unsafe_fragment.
    if blank_external_id?(invoice_attrs) do
      %Invoice{}
      |> Invoice.changeset(invoice_attrs)
      |> Repo.insert!()
    else
      %Invoice{}
      |> Invoice.changeset(invoice_attrs)
      |> Repo.insert!(
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target:
          {:unsafe_fragment, "(provider, external_id) WHERE external_id IS NOT NULL"}
      )
    end
  end
end
