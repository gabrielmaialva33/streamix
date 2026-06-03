defmodule StreamixWeb.BillingWebhookController do
  use StreamixWeb, :controller

  require Logger

  alias Streamix.Billing.Stripe

  # Stripe retries on timeout, so we have to answer quickly. Anything
  # that takes longer than this is almost certainly a sync reconciliation
  # path stuck on an external call — bail and let Stripe redeliver.
  @handler_timeout_ms 8_000

  def stripe(conn, _params) do
    raw_body = conn.assigns[:raw_body] || ""
    signature = conn |> get_req_header("stripe-signature") |> List.first()

    case with_timeout(fn -> Stripe.handle_webhook(raw_body, signature) end) do
      {:ok, _result} ->
        json(conn, %{received: true})

      {:error, reason}
      when reason in [:invalid_signature, :missing_signature, :stale_signature] ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{code: "invalid_signature", message: "Invalid Stripe signature"}})

      {:error, :handler_timeout} ->
        Logger.error("[Billing] Stripe webhook handler timed out after #{@handler_timeout_ms}ms")

        conn
        |> put_status(:service_unavailable)
        |> json(%{error: %{code: "timeout", message: "handler timed out, please retry"}})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "webhook_rejected", message: inspect(reason)}})
    end
  end

  # Run the handler inside a Task so we can hard-cap it. Stripe expects a
  # 2xx within ~10 s and will retry on timeout; without this guard a
  # stuck reconciliation call (e.g. Stripe.Client.list_subscriptions
  # talking back to Stripe) would pin the controller and force Stripe
  # into a retry storm.
  defp with_timeout(fun) do
    task = Task.async(fun)

    case Task.yield(task, @handler_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :handler_timeout}
      {:exit, reason} -> {:error, {:handler_crashed, reason}}
    end
  end
end
