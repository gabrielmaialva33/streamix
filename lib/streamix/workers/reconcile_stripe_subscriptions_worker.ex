defmodule Streamix.Workers.ReconcileStripeSubscriptionsWorker do
  @moduledoc """
  Reconciles local subscriptions with Stripe in case webhook delivery is missed.
  """

  use Oban.Worker, queue: :billing, max_attempts: 3

  alias Streamix.Billing.Stripe

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    case Stripe.reconcile_subscriptions() do
      {:ok, summary} ->
        Logger.info("Stripe reconciliation completed: #{inspect(summary)}")
        :ok

      {:error, :stripe_not_configured} ->
        Logger.info("Stripe reconciliation skipped: Stripe is not configured")
        :ok
    end
  end
end
