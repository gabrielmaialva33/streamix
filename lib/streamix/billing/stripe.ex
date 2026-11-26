defmodule Streamix.Billing.Stripe do
  @moduledoc """
  Stripe Checkout and webhook boundary for Streamix billing.
  """

  import Ecto.Query

  alias Streamix.Billing
  alias Streamix.Billing.Plan
  alias Streamix.Billing.Stripe.Client
  alias Streamix.Billing.Stripe.EventProcessor
  alias Streamix.Billing.Stripe.Webhook
  alias Streamix.Billing.Subscription
  alias Streamix.Repo

  def create_checkout_session(%{id: user_id, email: email} = user, %Plan{} = plan, attrs)
      when is_integer(user_id) and is_binary(email) and is_map(attrs) do
    with {:ok, secret_key} <- fetch_secret_key(),
         {:ok, success_url} <- fetch_required(attrs, :success_url),
         {:ok, cancel_url} <- fetch_required(attrs, :cancel_url),
         {:ok, stripe_session} <-
           Client.create_checkout_session(secret_key, checkout_form(user, plan, attrs)) do
      Billing.create_checkout_session(
        user,
        plan,
        checkout_session_attrs(stripe_session, success_url, cancel_url)
      )
    end
  end

  def create_portal_session(%{id: user_id} = user, return_url)
      when is_integer(user_id) and is_binary(return_url) do
    with {:ok, secret_key} <- fetch_secret_key(),
         %{external_id: customer_id} <- Billing.get_billing_customer(user, :stripe),
         {:ok, stripe_session} <-
           Client.create_portal_session(secret_key, customer_id, return_url) do
      {:ok, stripe_session["url"]}
    else
      nil -> {:error, :stripe_customer_not_found}
      error -> error
    end
  end

  def reconcile_subscriptions do
    with {:ok, secret_key} <- fetch_secret_key() do
      results =
        :stripe
        |> Billing.list_billing_customers()
        |> Enum.map(&reconcile_customer(&1, secret_key))

      failed = Enum.count(results, &(&1.status == :error))

      summary = %{
        customers: length(results),
        succeeded: length(results) - failed,
        failed: failed,
        results: results
      }

      if failed == 0, do: {:ok, summary}, else: {:error, summary}
    end
  end

  def handle_webhook(raw_body, signature_header) when is_binary(raw_body) do
    with {:ok, webhook_secret} <- fetch_webhook_secret(),
         {:ok, event} <- verify_webhook(raw_body, signature_header, webhook_secret) do
      EventProcessor.apply_event(event)
    end
  end

  def verify_webhook(raw_body, signature_header, webhook_secret)
      when is_binary(raw_body) and is_binary(signature_header) and is_binary(webhook_secret) do
    Webhook.verify(raw_body, signature_header, webhook_secret,
      tolerance_seconds: config_value(:webhook_tolerance_seconds, 300)
    )
  end

  def verify_webhook(_raw_body, _signature_header, _webhook_secret),
    do: {:error, :missing_signature}

  defdelegate apply_event(event), to: EventProcessor

  def retrieve_subscription(subscription_id) do
    with {:ok, secret_key} <- fetch_secret_key(),
         do: Client.retrieve_subscription(secret_key, subscription_id)
  end

  defp reconcile_customer(customer, secret_key) do
    case Client.list_subscriptions(secret_key, customer.external_id) do
      {:ok, subscriptions} ->
        synced =
          (Enum.map(subscriptions, & &1["id"]) ++ known_subscription_ids(customer.user_id))
          |> Enum.uniq()
          |> Enum.map(&EventProcessor.reconcile(&1, %{id: customer.user_id}))

        status = if Enum.all?(synced, &match?({:ok, _}, &1)), do: :ok, else: :error
        %{customer_id: customer.id, status: status, synced: synced}

      {:error, _reason} ->
        %{customer_id: customer.id, status: :error, reason: :upstream_failed}
    end
  end

  defp known_subscription_ids(user_id) do
    from(s in Subscription,
      where: s.user_id == ^user_id and s.source == "stripe",
      select: s.external_reference
    )
    |> Repo.all()
    |> Enum.flat_map(fn
      "stripe:" <> id -> [id]
      _ -> []
    end)
  end

  defp checkout_form(%{id: user_id, email: email}, %Plan{} = plan, attrs) do
    success_url = Map.fetch!(attrs, :success_url)
    cancel_url = Map.fetch!(attrs, :cancel_url)

    metadata = [
      {"metadata[user_id]", to_string(user_id)},
      {"metadata[plan_id]", to_string(plan.id)},
      {"metadata[plan_slug]", plan.slug},
      {"subscription_data[metadata][user_id]", to_string(user_id)},
      {"subscription_data[metadata][plan_id]", to_string(plan.id)},
      {"subscription_data[metadata][plan_slug]", plan.slug}
    ]

    [
      {"mode", "subscription"},
      {"success_url", success_url},
      {"cancel_url", cancel_url},
      {"client_reference_id", to_string(user_id)},
      {"line_items[0][quantity]", "1"}
    ] ++
      checkout_customer(user_id, email) ++
      checkout_line_item(plan) ++ trial_fields(plan) ++ metadata
  end

  defp checkout_customer(user_id, email) do
    case Billing.get_billing_customer(%{id: user_id}, :stripe) do
      %{external_id: customer_id} -> [{"customer", customer_id}]
      nil -> [{"customer_email", email}]
    end
  end

  defp checkout_line_item(%Plan{stripe_price_id: price_id})
       when is_binary(price_id) and price_id != "" do
    [{"line_items[0][price]", price_id}]
  end

  defp checkout_line_item(%Plan{} = plan) do
    [
      {"line_items[0][price_data][currency]", String.downcase(plan.currency)},
      {"line_items[0][price_data][unit_amount]", to_string(plan.price_cents)},
      {"line_items[0][price_data][product_data][name]", plan.name},
      {"line_items[0][price_data][recurring][interval]", plan.billing_interval}
    ]
  end

  defp trial_fields(%Plan{trial_days: trial_days})
       when is_integer(trial_days) and trial_days > 0 do
    [{"subscription_data[trial_period_days]", to_string(trial_days)}]
  end

  defp trial_fields(_plan), do: []

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
