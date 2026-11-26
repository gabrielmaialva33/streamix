defmodule Streamix.Billing.Stripe.EventProcessor do
  @moduledoc "Transactional event receipts and serialized authoritative subscription refresh."
  import Ecto.Query
  alias Streamix.Billing.{BillingCustomer, Stripe}
  alias Streamix.Billing.Stripe.Events
  alias Streamix.Repo

  @types ~w(checkout.session.completed checkout.session.async_payment_succeeded checkout.session.async_payment_failed invoice.paid invoice.payment_failed customer.subscription.updated customer.subscription.deleted)

  def apply_event(%{"type" => type} = event) when type in @types do
    with id when is_binary(id) and byte_size(id) in 1..255 <- event["id"],
         %{} = object <- get_in(event, ["data", "object"]),
         reference when is_binary(reference) <- Events.subscription_reference(object) do
      Repo.transaction(fn -> process_event!(id, type, object, reference, event) end)
    else
      _ -> {:error, :invalid_billing_event}
    end
  end

  def apply_event(_event), do: {:ok, :ignored}

  defp process_event!(id, type, object, reference, event) do
    lock("event:" <> id)

    if Repo.exists?(from(e in "stripe_webhook_events", where: e.external_id == ^id)) do
      :duplicate
    else
      subscription = refresh!(reference, nil)
      validate_subject!(object, subscription.user_id)
      result = payment_result!(event, subscription)

      Repo.insert_all("stripe_webhook_events", [
        %{external_id: id, event_type: type, processed_at: DateTime.utc_now(:second)}
      ])

      result
    end
  end

  def reconcile(subscription_id, fallback_user) when is_binary(subscription_id) do
    Repo.transaction(fn ->
      %{subscription: refresh!("stripe:" <> subscription_id, fallback_user)}
    end)
  end

  def reconcile(_id, _user), do: {:error, :invalid_subscription}

  defp refresh!("stripe:" <> subscription_id = reference, fallback_user) do
    lock(reference)

    with {:ok, %{"id" => ^subscription_id} = object} <-
           Stripe.retrieve_subscription(subscription_id),
         {:ok, %{subscription: subscription}} <-
           Events.sync_subscription_from_object(object, fallback_user || customer_user(object)) do
      subscription
    else
      {:error, reason} -> Repo.rollback(reason)
      _ -> Repo.rollback(:invalid_subscription)
    end
  end

  defp customer_user(%{"customer" => customer_id}) when is_binary(customer_id) do
    case Repo.get_by(BillingCustomer, provider: "stripe", external_id: customer_id) do
      %{user_id: user_id} -> %{id: user_id}
      nil -> nil
    end
  end

  defp customer_user(_object), do: nil

  defp validate_subject!(object, user_id) do
    case get_in(object, ["metadata", "user_id"]) do
      nil ->
        :ok

      value ->
        if to_string(value) != to_string(user_id), do: Repo.rollback(:billing_subject_mismatch)
    end
  end

  defp payment_result!(event, subscription) do
    case Events.record_payment_event(event, subscription) do
      {:ok, result} when is_map(result) -> Map.put(result, :subscription, subscription)
      {:ok, :ignored} -> %{subscription: subscription}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock(key),
    do: Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["stripe:" <> key])
end
