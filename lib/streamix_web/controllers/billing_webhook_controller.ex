defmodule StreamixWeb.BillingWebhookController do
  use StreamixWeb, :controller

  alias Streamix.Billing.Stripe

  def stripe(conn, _params) do
    raw_body = conn.assigns[:raw_body] || ""
    signature = conn |> get_req_header("stripe-signature") |> List.first()

    case Stripe.handle_webhook(raw_body, signature) do
      {:ok, _result} ->
        json(conn, %{received: true})

      {:error, reason}
      when reason in [:invalid_signature, :missing_signature, :stale_signature] ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{code: "invalid_signature", message: "Invalid Stripe signature"}})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "webhook_rejected", message: inspect(reason)}})
    end
  end
end
