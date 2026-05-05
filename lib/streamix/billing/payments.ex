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
      now = DateTime.utc_now() |> DateTime.truncate(:second)

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

  defp upsert_payment!(%User{} = user, %Plan{} = plan, %Subscription{} = subscription, attrs) do
    payment_attrs =
      attrs
      |> Map.put(:user_id, user.id)
      |> Map.put(:plan_id, plan.id)
      |> Map.put(:subscription_id, subscription.id)

    case existing_by_provider_external(Payment, payment_attrs) do
      nil ->
        %Payment{}
        |> Payment.changeset(payment_attrs)
        |> Repo.insert!()

      %Payment{} = payment ->
        payment
        |> Payment.changeset(payment_attrs)
        |> Repo.update!()
    end
  end

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

    case existing_by_provider_external(Invoice, invoice_attrs) do
      nil ->
        %Invoice{}
        |> Invoice.changeset(invoice_attrs)
        |> Repo.insert!()

      %Invoice{} = invoice ->
        invoice
        |> Invoice.changeset(invoice_attrs)
        |> Repo.update!()
    end
  end

  defp existing_by_provider_external(schema, %{provider: provider, external_id: external_id})
       when is_binary(external_id) and external_id != "" do
    Repo.get_by(schema, provider: provider, external_id: external_id)
  end

  defp existing_by_provider_external(_schema, _attrs), do: nil
end
