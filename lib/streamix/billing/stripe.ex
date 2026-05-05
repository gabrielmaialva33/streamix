defmodule Streamix.Billing.Stripe do
  @moduledoc """
  Stripe Checkout and webhook boundary for Streamix billing.
  """

  alias Streamix.Accounts.User
  alias Streamix.Billing
  alias Streamix.Billing.Plan
  alias Streamix.Repo

  @checkout_sessions_url "https://api.stripe.com/v1/checkout/sessions"
  @billing_portal_sessions_url "https://api.stripe.com/v1/billing_portal/sessions"
  @webhook_tolerance_seconds 300

  def create_checkout_session(%User{} = user, %Plan{} = plan, attrs) when is_map(attrs) do
    with {:ok, secret_key} <- fetch_secret_key(),
         {:ok, success_url} <- fetch_required(attrs, :success_url),
         {:ok, cancel_url} <- fetch_required(attrs, :cancel_url),
         {:ok, stripe_session} <- request_checkout_session(secret_key, user, plan, attrs) do
      Billing.create_checkout_session(
        user,
        plan,
        checkout_session_attrs(stripe_session, success_url, cancel_url)
      )
    end
  end

  def create_portal_session(%User{} = user, return_url) when is_binary(return_url) do
    with {:ok, secret_key} <- fetch_secret_key(),
         %{external_id: customer_id} <- Billing.get_billing_customer(user, :stripe),
         {:ok, stripe_session} <- request_portal_session(secret_key, customer_id, return_url) do
      {:ok, stripe_session["url"]}
    else
      nil -> {:error, :stripe_customer_not_found}
      error -> error
    end
  end

  def handle_webhook(raw_body, signature_header) when is_binary(raw_body) do
    with {:ok, webhook_secret} <- fetch_webhook_secret(),
         {:ok, event} <- verify_webhook(raw_body, signature_header, webhook_secret) do
      apply_event(event)
    end
  end

  def verify_webhook(raw_body, signature_header, webhook_secret)
      when is_binary(raw_body) and is_binary(signature_header) and is_binary(webhook_secret) do
    with {:ok, timestamp, signatures} <- parse_signature_header(signature_header),
         :ok <- verify_timestamp(timestamp),
         true <- valid_signature?(raw_body, timestamp, signatures, webhook_secret),
         {:ok, event} <- Phoenix.json_library().decode(raw_body) do
      {:ok, event}
    else
      false -> {:error, :invalid_signature}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_webhook(_raw_body, _signature_header, _webhook_secret),
    do: {:error, :missing_signature}

  def apply_event(
        %{"type" => "checkout.session.completed", "data" => %{"object" => object}} = event
      ) do
    activate_from_stripe_object(object, event)
  end

  def apply_event(%{"type" => "invoice.paid", "data" => %{"object" => object}} = event) do
    activate_from_stripe_object(object, event)
  end

  def apply_event(%{"type" => "invoice.payment_failed", "data" => %{"object" => object}}) do
    mark_subscription_from_object(object, "pending")
  end

  def apply_event(%{"type" => "customer.subscription.updated", "data" => %{"object" => object}}) do
    sync_subscription_from_object(object)
  end

  def apply_event(
        %{"type" => "customer.subscription.deleted", "data" => %{"object" => object}} = _event
      ) do
    case object["id"] do
      subscription_id when is_binary(subscription_id) ->
        {:ok, Billing.cancel_subscription_by_external_reference!("stripe:#{subscription_id}")}

      _ ->
        {:ok, :ignored}
    end
  end

  def apply_event(_event), do: {:ok, :ignored}

  defp request_checkout_session(secret_key, %User{} = user, %Plan{} = plan, attrs) do
    http_client = config_value(:http_client, Req)
    url = config_value(:checkout_sessions_url, @checkout_sessions_url)

    case http_client.post(url,
           body:
             user
             |> checkout_form(plan, attrs)
             |> URI.encode_query(),
           headers: [
             {"authorization", "Bearer #{secret_key}"},
             {"content-type", "application/x-www-form-urlencoded"}
           ],
           finch: Streamix.Finch,
           receive_timeout: 15_000
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:stripe_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_portal_session(secret_key, customer_id, return_url) do
    http_client = config_value(:http_client, Req)
    url = config_value(:billing_portal_sessions_url, @billing_portal_sessions_url)

    case http_client.post(url,
           body: URI.encode_query(%{customer: customer_id, return_url: return_url}),
           headers: [
             {"authorization", "Bearer #{secret_key}"},
             {"content-type", "application/x-www-form-urlencoded"}
           ],
           finch: Streamix.Finch,
           receive_timeout: 15_000
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:stripe_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp checkout_form(%User{} = user, %Plan{} = plan, attrs) do
    success_url = Map.fetch!(attrs, :success_url)
    cancel_url = Map.fetch!(attrs, :cancel_url)

    metadata = [
      {"metadata[user_id]", to_string(user.id)},
      {"metadata[plan_id]", to_string(plan.id)},
      {"metadata[plan_slug]", plan.slug},
      {"subscription_data[metadata][user_id]", to_string(user.id)},
      {"subscription_data[metadata][plan_id]", to_string(plan.id)},
      {"subscription_data[metadata][plan_slug]", plan.slug}
    ]

    [
      {"mode", "subscription"},
      {"success_url", success_url},
      {"cancel_url", cancel_url},
      {"client_reference_id", to_string(user.id)},
      {"customer_email", user.email},
      {"line_items[0][price_data][currency]", String.downcase(plan.currency)},
      {"line_items[0][price_data][unit_amount]", to_string(plan.price_cents)},
      {"line_items[0][price_data][product_data][name]", plan.name},
      {"line_items[0][price_data][recurring][interval]", plan.billing_interval},
      {"line_items[0][quantity]", "1"}
    ] ++ metadata
  end

  defp checkout_session_attrs(stripe_session, success_url, cancel_url) do
    %{
      provider: "stripe",
      status: normalize_checkout_status(stripe_session["status"]),
      external_id: stripe_session["id"],
      checkout_url: stripe_session["url"],
      success_url: success_url,
      cancel_url: cancel_url,
      expires_at: unix_to_datetime(stripe_session["expires_at"]),
      metadata: stripe_session["metadata"] || %{}
    }
  end

  defp activate_from_stripe_object(object, event) do
    with {:ok, user_id} <- fetch_metadata_id(object, "user_id"),
         {:ok, plan_id} <- fetch_metadata_id(object, "plan_id"),
         %User{} = user <- Repo.get(User, user_id),
         %Plan{} = plan <- Repo.get(Plan, plan_id) do
      maybe_upsert_customer!(user, object)

      result =
        Billing.activate_subscription_from_payment!(user, plan, %{
          provider: "stripe",
          external_id: stripe_payment_external_id(object, event),
          subscription_external_reference: stripe_subscription_reference(object),
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

  defp sync_subscription_from_object(object) do
    with {:ok, user_id} <- fetch_metadata_id(object, "user_id"),
         {:ok, plan_id} <- fetch_metadata_id(object, "plan_id"),
         %User{} = user <- Repo.get(User, user_id),
         %Plan{} = plan <- Repo.get(Plan, plan_id) do
      maybe_upsert_customer!(user, object)

      subscription =
        Billing.sync_provider_subscription!(user, plan, %{
          provider: "stripe",
          external_reference: stripe_subscription_reference(object),
          status: subscription_status(object["status"]),
          starts_at:
            unix_to_datetime(object["current_period_start"]) || DateTime.utc_now(:second),
          expires_at: subscription_expires_at(object),
          canceled_at: unix_to_datetime(object["canceled_at"])
        })

      {:ok, %{subscription: subscription}}
    else
      nil -> {:error, :unknown_billing_subject}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_subscription_from_object(object, status) do
    with reference when is_binary(reference) <- stripe_subscription_reference(object),
         {:ok, user_id} <- fetch_metadata_id(object, "user_id"),
         {:ok, plan_id} <- fetch_metadata_id(object, "plan_id"),
         %User{} = user <- Repo.get(User, user_id),
         %Plan{} = plan <- Repo.get(Plan, plan_id) do
      subscription =
        Billing.sync_provider_subscription!(user, plan, %{
          provider: "stripe",
          external_reference: reference,
          status: status,
          starts_at: unix_to_datetime(object["period_start"]) || DateTime.utc_now(:second),
          expires_at: unix_to_datetime(object["period_end"])
        })

      {:ok, %{subscription: subscription}}
    else
      nil -> {:ok, :ignored}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stripe_invoice_attrs(object, %Plan{} = plan, event) do
    %{
      status: stripe_invoice_status(object),
      external_id: object["invoice"] || invoice_object_id(object),
      number: object["number"],
      amount_due_cents: object["amount_due"] || stripe_amount_cents(object, plan),
      amount_paid_cents: object["amount_paid"] || stripe_amount_cents(object, plan),
      currency: stripe_currency(object, plan),
      hosted_invoice_url: object["hosted_invoice_url"],
      paid_at: stripe_paid_at(object, event),
      metadata: object["metadata"] || %{}
    }
  end

  defp stripe_payment_external_id(object, event) do
    object["payment_intent"] || object["id"] || event["id"]
  end

  defp stripe_subscription_reference(object) do
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

  defp subscription_expires_at(%{"cancel_at_period_end" => true} = object),
    do: unix_to_datetime(object["current_period_end"])

  defp subscription_expires_at(_object), do: nil

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

  defp maybe_upsert_customer!(%User{} = user, object) do
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

  defp parse_signature_header(header) do
    parts =
      header
      |> String.split(",", trim: true)
      |> Enum.map(fn part -> String.split(part, "=", parts: 2) end)

    timestamp =
      Enum.find_value(parts, fn
        ["t", value] -> parse_integer(value)
        _ -> nil
      end)

    signatures =
      Enum.flat_map(parts, fn
        ["v1", value] -> [value]
        _ -> []
      end)

    if timestamp && signatures != [] do
      {:ok, timestamp, signatures}
    else
      {:error, :invalid_signature_header}
    end
  end

  defp verify_timestamp(timestamp) do
    tolerance = config_value(:webhook_tolerance_seconds, @webhook_tolerance_seconds)

    if abs(System.system_time(:second) - timestamp) <= tolerance do
      :ok
    else
      {:error, :stale_signature}
    end
  end

  defp valid_signature?(raw_body, timestamp, signatures, webhook_secret) do
    signed_payload = "#{timestamp}.#{raw_body}"

    expected =
      :hmac
      |> :crypto.mac(:sha256, webhook_secret, signed_payload)
      |> Base.encode16(case: :lower)

    Enum.any?(signatures, &Plug.Crypto.secure_compare(expected, &1))
  end

  defp normalize_checkout_status(status)
       when status in ~w(open complete completed expired canceled),
       do: if(status == "complete", do: "completed", else: status)

  defp normalize_checkout_status(_status), do: "open"

  defp unix_to_datetime(nil), do: nil

  defp unix_to_datetime(timestamp) when is_integer(timestamp) do
    timestamp
    |> DateTime.from_unix!()
    |> DateTime.truncate(:second)
  end

  defp fetch_required(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_required, key}}
    end
  end

  defp fetch_secret_key do
    case config_value(:secret_key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :stripe_not_configured}
    end
  end

  defp fetch_webhook_secret do
    case config_value(:webhook_secret) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :stripe_webhook_not_configured}
    end
  end

  defp config_value(key, default \\ nil) do
    :streamix
    |> Application.get_env(:stripe, [])
    |> Keyword.get(key, default)
  end
end
