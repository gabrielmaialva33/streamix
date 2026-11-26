defmodule Streamix.Workers.ReconcileStripeSubscriptionsWorker do
  @moduledoc """
  Reconciles local subscriptions with Stripe in case webhook delivery is missed.
  """

  use Oban.Worker, queue: :billing, max_attempts: 3

  alias Streamix.Billing

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    case Billing.reconcile_stripe_subscriptions() do
      {:ok, summary} ->
        Logger.info("Stripe reconciliation completed",
          billing_customers: summary.customers,
          billing_failed: 0
        )

        :ok

      {:error, %{customers: customers, failed: failed}} ->
        Logger.warning("Stripe reconciliation incomplete",
          billing_customers: customers,
          billing_failed: failed
        )

        {:error, {:stripe_reconciliation_incomplete, failed}}

      {:error, :stripe_not_configured} ->
        Logger.info("Stripe reconciliation skipped: Stripe is not configured")
        :ok
    end
  end
end
