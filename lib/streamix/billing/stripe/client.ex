defmodule Streamix.Billing.Stripe.Client do
  @moduledoc """
  Low-level Stripe HTTP client.
  """

  @checkout_sessions_url "https://api.stripe.com/v1/checkout/sessions"
  @billing_portal_sessions_url "https://api.stripe.com/v1/billing_portal/sessions"
  @subscriptions_url "https://api.stripe.com/v1/subscriptions"
  @receive_timeout 15_000

  def create_checkout_session(secret_key, form) when is_list(form) do
    post_form(config_value(:checkout_sessions_url, @checkout_sessions_url), secret_key, form)
  end

  def create_portal_session(secret_key, customer_id, return_url) do
    form = %{customer: customer_id, return_url: return_url}

    post_form(
      config_value(:billing_portal_sessions_url, @billing_portal_sessions_url),
      secret_key,
      form
    )
  end

  def list_subscriptions(secret_key, customer_id) do
    url = config_value(:subscriptions_url, @subscriptions_url)
    query = URI.encode_query(%{customer: customer_id, status: "all", limit: "100"})

    case http_client().get("#{url}?#{query}",
           headers: authorization_headers(secret_key),
           finch: Streamix.Finch,
           receive_timeout: @receive_timeout
         ) do
      {:ok, %Req.Response{status: status, body: %{"data" => data}}} when status in 200..299 ->
        {:ok, data}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:stripe_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post_form(url, secret_key, form) do
    case http_client().post(url,
           body: URI.encode_query(form),
           headers: authorization_headers(secret_key) ++ content_type_headers(),
           finch: Streamix.Finch,
           receive_timeout: @receive_timeout
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:stripe_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp authorization_headers(secret_key), do: [{"authorization", "Bearer #{secret_key}"}]
  defp content_type_headers, do: [{"content-type", "application/x-www-form-urlencoded"}]

  defp http_client, do: config_value(:http_client, Req)

  defp config_value(key, default) do
    :streamix
    |> Application.get_env(:stripe, [])
    |> Keyword.get(key, default)
  end
end
