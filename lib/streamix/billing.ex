defmodule Streamix.Billing do
  @moduledoc """
  Billing context facade.

  Public callers use this module; focused submodules own the implementation
  for plans, entitlements, subscriptions, payments, customers, playback slots
  and admin aggregates.
  """

  alias Streamix.Billing.{
    Admin,
    Customers,
    Entitlements,
    Payments,
    Plans,
    PlaybackSessions,
    Stripe,
    Subscriptions
  }

  # Plans
  defdelegate new_plan(), to: Plans
  defdelegate change_plan(plan, attrs \\ %{}), to: Plans
  defdelegate list_active_plans(), to: Plans
  defdelegate ensure_plan!(attrs), to: Plans
  defdelegate sync_plan_features!(plan, features), to: Plans
  defdelegate list_plans(), to: Plans
  defdelegate get_plan!(id), to: Plans
  defdelegate get_plan_with_features!(id), to: Plans
  defdelegate plan_feature_enabled?(plan, feature, default), to: Plans, as: :feature_enabled?
  defdelegate plan_feature_limit(plan, feature), to: Plans, as: :feature_limit
  defdelegate get_plan_by_slug(slug), to: Plans
  defdelegate create_plan(attrs), to: Plans
  defdelegate update_plan(plan, attrs), to: Plans
  defdelegate get_plan_by_stripe_price_id(price_id), to: Plans

  # Entitlements and limits
  defdelegate entitled?(user, feature), to: Entitlements
  defdelegate entitled_user_id?(user_id, feature), to: Entitlements
  defdelegate feature_limit_for(user, feature), to: Entitlements
  defdelegate feature_limit_for_user_id(user_id, feature), to: Entitlements
  defdelegate subscribed?(user), to: Entitlements
  defdelegate active_subscription_for_user(user), to: Entitlements

  # Checkout, payments and invoices
  defdelegate create_checkout_session(user, plan, attrs), to: Payments
  defdelegate activate_subscription_from_payment!(user, plan, attrs), to: Payments
  defdelegate list_invoices(user), to: Payments
  defdelegate list_payments(user), to: Payments
  defdelegate list_recent_payments(), to: Payments
  defdelegate list_recent_payments(limit), to: Payments
  defdelegate list_recent_invoices(), to: Payments
  defdelegate list_recent_invoices(limit), to: Payments

  # Stripe boundary
  defdelegate create_stripe_checkout_session(user, plan, attrs),
    to: Stripe,
    as: :create_checkout_session

  defdelegate create_stripe_portal_session(user, return_url),
    to: Stripe,
    as: :create_portal_session

  defdelegate reconcile_stripe_subscriptions(), to: Stripe, as: :reconcile_subscriptions
  defdelegate handle_stripe_webhook(raw_body, signature), to: Stripe, as: :handle_webhook

  # Provider customers
  defdelegate get_billing_customer(user, provider), to: Customers
  defdelegate list_billing_customers(provider), to: Customers
  defdelegate upsert_billing_customer!(user, provider, external_id), to: Customers
  defdelegate upsert_billing_customer!(user, provider, external_id, metadata), to: Customers

  # Playback slot enforcement
  defdelegate start_playback_session(user, attrs), to: PlaybackSessions
  defdelegate touch_playback_session(playback_session), to: PlaybackSessions
  defdelegate end_playback_session(playback_session), to: PlaybackSessions
  defdelegate active_playback_count(user), to: PlaybackSessions

  # Subscription lifecycle
  defdelegate cancel_subscription_by_external_reference!(external_reference), to: Subscriptions
  defdelegate sync_provider_subscription!(user, plan, attrs), to: Subscriptions
  defdelegate ensure_default_free_subscription(user), to: Subscriptions
  defdelegate start_trial_subscription(user, plan), to: Subscriptions
  defdelegate ensure_manual_subscription!(user, plan, attrs), to: Subscriptions
  defdelegate create_manual_subscription(user, plan, attrs), to: Subscriptions
  defdelegate cancel_subscription!(subscription), to: Subscriptions
  defdelegate list_subscriptions(), to: Subscriptions
  defdelegate list_subscriptions(opts), to: Subscriptions

  # Admin
  defdelegate admin_stats(), to: Admin
end
