defmodule Streamix.Billing.Stripe.Events do
  @moduledoc """
  Applies Stripe webhook and reconciliation payloads to local billing state.
  """

  alias Streamix.Accounts
  alias Streamix.Billing
  alias Streamix.Billing.{BillingCustomer, Plan, Subscription}
  alias Streamix.Repo

  @payment_events ~w(checkout.session.completed checkout.session.async_payment_succeeded checkout.session.async_payment_failed invoice.paid invoice.payment_failed)

  def record_payment_event(
        %{"type" => type, "data" => %{"object" => object}} = event,
        subscription
      )
      when type in @payment_events do
    object =
      case type do
        "checkout.session.async_payment_succeeded" -> Map.put(object, "payment_status", "paid")
        "checkout.session.async_payment_failed" -> Map.put(object, "payment_status", "failed")
        "invoice.payment_failed" -> Map.put(object, "payment_status", "failed")
        _ -> object
      end

    # Identity comes from the refreshed subscription, not stale checkout metadata.
    metadata = (object["metadata"] || %{}) |> Map.put("user_id", subscription.user_id)
    metadata = Map.put_new(metadata, "plan_id", subscription.plan_id)
    activate_from_stripe_object(Map.put(object, "metadata", metadata), event)
  end

  def record_payment_event(_event, _subscription), do: {:ok, :ignored}

  def sync_subscription_from_object(object, fallback_user \\ nil) do
    with %{id: user_id} = user when is_integer(user_id) <-
           user_from_stripe_object(object, fallback_user),
         %Plan{} = plan <- plan_from_stripe_object(object),
         :ok <- validate_owner(object, user_id),
         {:ok, starts_at, expires_at} <- billing_period(object) do
      maybe_upsert_customer!(user, object)

      subscription =
        Billing.sync_provider_subscription!(user, plan, %{
          provider: "stripe",
          external_reference: subscription_reference(object),
          status: subscription_status(object["status"]),
          starts_at: starts_at,
          expires_at: expires_at,
          canceled_at: unix_to_datetime(object["canceled_at"])
        })

      {:ok, %{subscription: subscription}}
    else
      nil -> {:error, :unknown_billing_subject}
      {:error, reason} -> {:error, reason}
    end
  end

  defp activate_from_stripe_object(object, event) do
    with {:ok, user_id} <- fetch_metadata_id(object, "user_id"),
         %{id: ^user_id} = user <- Accounts.get_user(user_id),
         %Plan{} = plan <- plan_from_stripe_object(object) do
      maybe_upsert_customer!(user, object)

      result =
        Billing.activate_subscription_from_payment!(user, plan, %{
          provider: "stripe",
          grant_access?: false,
          external_id: stripe_payment_external_id(object, event),
          subscription_external_reference: subscription_reference(object),
          status: stripe_payment_status(object),
          amount_cents: stripe_amount_cents(object, plan),
          currency: stripe_currency(object, plan),
          paid_at: stripe_paid_at(object, event),
          raw_event: event,
          invoice: stripe_invoice_attrs(object, plan, event)
        })

      {:ok, result}
    else
      nil -> {:error, :unknown_billing_subject}
      {:error, reason} -> {:error, reason}
    end
  end

  defp user_from_stripe_object(object, fallback_user) do
    case fetch_metadata_id(object, "user_id") do
      {:ok, user_id} -> Accounts.get_user(user_id) || fallback_user
      {:error, :missing_metadata} -> fallback_user
    end
  end

  defp stripe_invoice_attrs(object, %Plan{} = plan, event) do
    %{
      status: stripe_invoice_status(object),
      external_id: object["invoice"] || invoice_object_id(object),
      number: object["number"],
      amount_due_cents: object["amount_due"] || stripe_amount_cents(object, plan),
      amount_paid_cents:
        object["amount_paid"] ||
          if(stripe_payment_status(object) == "paid",
            do: stripe_amount_cents(object, plan),
            else: 0
          ),
      currency: stripe_currency(object, plan),
      hosted_invoice_url: object["hosted_invoice_url"],
      paid_at: if(stripe_payment_status(object) == "paid", do: stripe_paid_at(object, event)),
      metadata: object["metadata"] || %{}
    }
  end

  defp plan_from_stripe_object(object) do
    case fetch_metadata_id(object, "plan_id") do
      {:ok, plan_id} ->
        Repo.get(Plan, plan_id)

      {:error, :missing_metadata} ->
        object
        |> stripe_price_ids()
        |> Enum.find_value(&Billing.get_plan_by_stripe_price_id/1)
    end
  end

  defp stripe_price_ids(object) do
    [
      get_in(object, ["items", "data", Access.at(0), "price", "id"]),
      get_in(object, ["lines", "data", Access.at(0), "price", "id"]),
      get_in(object, ["display_items", Access.at(0), "price", "id"])
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp stripe_payment_external_id(object, event) do
    object["payment_intent"] || object["id"] || event["id"]
  end

  def subscription_reference(object) do
    id =
      cond do
        is_binary(object["subscription"]) -> object["subscription"]
        is_binary(invoice_subscription_id(object)) -> invoice_subscription_id(object)
        object["object"] == "subscription" -> object["id"]
        true -> nil
      end

    case id do
      subscription_id when is_binary(subscription_id) -> "stripe:#{subscription_id}"
      _ -> nil
    end
  end

  defp invoice_subscription_id(object) do
    get_in(object, ["parent", "subscription_details", "subscription"])
  end

  defp subscription_status(status) when status in ~w(active trialing), do: "active"
  defp subscription_status(status) when status in ~w(canceled unpaid), do: "canceled"
  defp subscription_status(_status), do: "pending"

  defp billing_period(object) do
    starts_at =
      unix_to_datetime(period_field(object, "current_period_start")) || DateTime.utc_now(:second)

    expires_at =
      unix_to_datetime(period_field(object, "current_period_end") || object["trial_end"])

    cond do
      object["status"] in ~w(active trialing) and is_nil(expires_at) ->
        {:error, :missing_billing_period}

      expires_at && DateTime.compare(expires_at, starts_at) != :gt ->
        {:error, :invalid_billing_period}

      true ->
        {:ok, starts_at, expires_at}
    end
  end

  defp period_field(object, field),
    do: object[field] || get_in(object, ["items", "data", Access.at(0), field])

  defp validate_owner(object, user_id) do
    subscription = Repo.get_by(Subscription, external_reference: subscription_reference(object))

    customer =
      if id = object["customer"],
        do: Repo.get_by(BillingCustomer, provider: "stripe", external_id: id)

    if Enum.any?([subscription, customer], &(not is_nil(&1) and &1.user_id != user_id)),
      do: {:error, :billing_subject_mismatch},
      else: :ok
  end

  defp stripe_payment_status(%{"payment_status" => "failed"}), do: "failed"
  defp stripe_payment_status(%{"payment_status" => "paid"}), do: "paid"
  defp stripe_payment_status(%{"status" => "paid"}), do: "paid"
  defp stripe_payment_status(%{"paid" => true}), do: "paid"
  defp stripe_payment_status(_object), do: "pending"

  defp stripe_invoice_status(%{"status" => status})
       when status in ~w(draft open paid void uncollectible),
       do: status

  defp stripe_invoice_status(%{"payment_status" => "paid"}), do: "paid"
  defp stripe_invoice_status(_object), do: "open"

  defp stripe_amount_cents(object, %Plan{} = plan) do
    object["amount_total"] || object["amount_paid"] || object["amount_due"] || plan.price_cents
  end

  defp stripe_currency(object, %Plan{} = plan) do
    case object["currency"] do
      currency when is_binary(currency) -> String.upcase(currency)
      _ -> plan.currency
    end
  end

  defp stripe_paid_at(object, event) do
    object
    |> get_in(["status_transitions", "paid_at"])
    |> Kernel.||(event["created"])
    |> unix_to_datetime()
  end

  defp invoice_object_id(%{"object" => "invoice", "id" => invoice_id}), do: invoice_id
  defp invoice_object_id(_object), do: nil

  defp fetch_metadata_id(object, key) do
    object
    |> metadata_candidates()
    |> Enum.find_value(fn metadata ->
      metadata
      |> Map.get(key)
      |> parse_integer()
    end)
    |> case do
      nil -> {:error, :missing_metadata}
      id -> {:ok, id}
    end
  end

  defp metadata_candidates(object) do
    [
      object["metadata"],
      object["lines"] && get_in(object, ["lines", "data", Access.at(0), "metadata"]),
      get_in(object, ["subscription_details", "metadata"]),
      get_in(object, ["parent", "subscription_details", "metadata"])
    ]
    |> Enum.filter(&is_map/1)
  end

  defp maybe_upsert_customer!(%{id: user_id} = user, object) when is_integer(user_id) do
    case object["customer"] do
      customer_id when is_binary(customer_id) ->
        Billing.upsert_billing_customer!(
          user,
          :stripe,
          customer_id,
          object["customer_details"] || %{}
        )

      _ ->
        nil
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp unix_to_datetime(nil), do: nil

  defp unix_to_datetime(timestamp) when is_integer(timestamp) do
    timestamp
    |> DateTime.from_unix!()
    |> DateTime.truncate(:second)
  end
end
