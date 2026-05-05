defmodule Streamix.Billing do
  @moduledoc """
  Billing context for plans and subscriptions.
  """

  import Ecto.Query, warn: false

  alias Streamix.Accounts.User

  alias Streamix.Billing.{
    BillingCustomer,
    CheckoutSession,
    Invoice,
    Payment,
    Plan,
    PlanFeature,
    PlaybackSession,
    Subscription
  }

  alias Streamix.Repo

  def list_active_plans do
    from(p in Plan,
      where: p.active == true,
      order_by: [asc: p.price_cents, asc: p.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Finds or creates a plan keyed by slug and keeps its attributes in sync.
  """
  def ensure_plan!(attrs) when is_map(attrs) do
    slug = Map.fetch!(attrs, :slug)

    features = Map.get(attrs, :features, %{})
    plan_attrs = Map.delete(attrs, :features)

    plan =
      case Repo.get_by(Plan, slug: slug) do
        nil ->
          %Plan{}
          |> Plan.changeset(plan_attrs)
          |> Repo.insert!()

        %Plan{} = plan ->
          plan
          |> Plan.changeset(Map.merge(current_plan_attrs(plan), plan_attrs))
          |> Repo.update!()
      end

    sync_plan_features!(plan, features)

    plan
  end

  def entitled?(%User{id: user_id}, feature) do
    entitled_user_id?(user_id, feature)
  end

  def entitled?(_user, _feature), do: false

  def entitled_user_id?(user_id, feature) when is_integer(user_id) do
    feature = normalize_feature(feature)

    has_active_feature?(user_id, feature) or
      (feature == "global_catalog" and has_legacy_global_access?(user_id))
  end

  def entitled_user_id?(_user_id, _feature), do: false

  def feature_limit_for(%User{id: user_id}, feature) do
    feature_limit_for_user_id(user_id, feature)
  end

  def feature_limit_for(_user, _feature), do: nil

  def feature_limit_for_user_id(user_id, feature) when is_integer(user_id) do
    feature = normalize_feature(feature)

    from(s in active_subscription_query(user_id),
      join: p in assoc(s, :plan),
      join: f in PlanFeature,
      on: f.plan_id == s.plan_id,
      where: p.active == true,
      where: f.feature == ^feature and f.enabled == true and not is_nil(f.limit),
      select: max(f.limit)
    )
    |> Repo.one()
  end

  def feature_limit_for_user_id(_user_id, _feature), do: nil

  def sync_plan_features!(%Plan{} = plan, features) when is_map(features) do
    Enum.each(features, fn {feature, value} ->
      upsert_plan_feature!(plan, feature, value)
    end)

    Repo.preload(plan, :features, force: true)
  end

  def sync_plan_features!(%Plan{} = plan, _features), do: plan

  def create_checkout_session(%User{} = user, %Plan{} = plan, attrs) do
    %CheckoutSession{}
    |> CheckoutSession.create_changeset(user, plan, Map.merge(%{status: "pending"}, attrs))
    |> Repo.insert()
  end

  def activate_subscription_from_payment!(%User{} = user, %Plan{} = plan, attrs)
      when is_map(attrs) do
    Repo.transaction(fn ->
      provider = Map.fetch!(attrs, :provider)
      external_id = Map.get(attrs, :external_id)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      external_reference =
        Map.get(attrs, :subscription_external_reference) ||
          payment_subscription_reference(provider, external_id, user, plan)

      cancel_other_active_subscriptions!(user.id, external_reference, now)

      subscription =
        ensure_manual_subscription!(user, plan, %{
          status: "active",
          source: provider,
          external_reference: external_reference,
          starts_at: Map.get(attrs, :starts_at, now),
          expires_at: Map.get(attrs, :expires_at)
        })

      payment =
        upsert_payment!(user, plan, subscription, %{
          provider: provider,
          status: Map.get(attrs, :status, "paid"),
          external_id: external_id,
          amount_cents: Map.get(attrs, :amount_cents, plan.price_cents),
          currency: Map.get(attrs, :currency, plan.currency),
          paid_at: Map.get(attrs, :paid_at, now),
          failure_reason: Map.get(attrs, :failure_reason),
          raw_event: Map.get(attrs, :raw_event, %{})
        })

      invoice =
        maybe_upsert_invoice!(user, plan, subscription, attrs, now)

      %{subscription: subscription, payment: payment, invoice: invoice}
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> raise inspect(reason)
    end
  end

  def list_invoices(%User{id: user_id}) do
    from(i in Invoice,
      where: i.user_id == ^user_id,
      preload: [:plan, :subscription],
      order_by: [desc: i.inserted_at, desc: i.id]
    )
    |> Repo.all()
  end

  def list_payments(%User{id: user_id}) do
    from(p in Payment,
      where: p.user_id == ^user_id,
      preload: [:plan, :subscription],
      order_by: [desc: p.inserted_at, desc: p.id]
    )
    |> Repo.all()
  end

  def get_billing_customer(%User{id: user_id}, provider) do
    Repo.get_by(BillingCustomer, user_id: user_id, provider: normalize_provider(provider))
  end

  def upsert_billing_customer!(%User{} = user, provider, external_id, metadata \\ %{})
      when is_binary(external_id) and external_id != "" do
    attrs = %{
      user_id: user.id,
      provider: normalize_provider(provider),
      external_id: external_id,
      metadata: metadata || %{}
    }

    case Repo.get_by(BillingCustomer, user_id: user.id, provider: attrs.provider) do
      nil ->
        %BillingCustomer{}
        |> BillingCustomer.changeset(attrs)
        |> Repo.insert!()

      %BillingCustomer{} = customer ->
        customer
        |> BillingCustomer.changeset(attrs)
        |> Repo.update!()
    end
  end

  def start_playback_session(%User{} = user, attrs) when is_map(attrs) do
    cleanup_stale_playback_sessions!(user.id)

    with :ok <- ensure_playback_slot_available(user) do
      now = DateTime.utc_now(:second)

      attrs =
        attrs
        |> Map.put(:user_id, user.id)
        |> Map.put_new(:session_id, playback_session_id())
        |> Map.put_new(:status, "active")
        |> Map.put_new(:started_at, now)
        |> Map.put(:last_seen_at, now)

      %PlaybackSession{}
      |> PlaybackSession.changeset(attrs)
      |> Repo.insert()
    end
  end

  def touch_playback_session(nil), do: :ok

  def touch_playback_session(%PlaybackSession{} = playback_session) do
    playback_session
    |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now(:second))
    |> Repo.update()
    |> case do
      {:ok, _session} -> :ok
      {:error, _changeset} -> :ok
    end
  end

  def end_playback_session(nil), do: :ok

  def end_playback_session(%PlaybackSession{} = playback_session) do
    now = DateTime.utc_now(:second)

    playback_session
    |> Ecto.Changeset.change(status: "ended", ended_at: now, last_seen_at: now)
    |> Repo.update()
    |> case do
      {:ok, _session} -> :ok
      {:error, _changeset} -> :ok
    end
  end

  def active_playback_count(%User{id: user_id}) do
    cleanup_stale_playback_sessions!(user_id)

    from(ps in PlaybackSession,
      where: ps.user_id == ^user_id and ps.status == "active"
    )
    |> Repo.aggregate(:count)
  end

  def subscribed?(%User{id: user_id}) do
    has_legacy_global_access?(user_id) or has_active_feature?(user_id, "global_catalog")
  end

  def subscribed?(_user), do: false

  def active_subscription_for_user(%User{id: user_id}) do
    query =
      from(s in active_subscription_query(user_id),
        join: p in assoc(s, :plan),
        left_join: f in assoc(p, :features),
        where: p.active == true,
        where:
          p.grants_global_access == true or (f.feature == "global_catalog" and f.enabled == true),
        order_by: [desc: s.inserted_at, desc: s.id],
        limit: 1
      )

    case Repo.one(query) do
      nil -> nil
      %Subscription{} = subscription -> Repo.preload(subscription, plan: :features)
    end
  end

  def active_subscription_for_user(_user), do: nil

  def cancel_subscription_by_external_reference!(external_reference)
      when is_binary(external_reference) do
    case Repo.get_by(Subscription, external_reference: external_reference) do
      nil ->
        nil

      %Subscription{} = subscription ->
        cancel_subscription!(subscription)
    end
  end

  def sync_provider_subscription!(%User{} = user, %Plan{} = plan, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      now = DateTime.utc_now(:second)
      external_reference = Map.fetch!(attrs, :external_reference)
      status = Map.fetch!(attrs, :status)

      if status == "active" do
        cancel_other_active_subscriptions!(user.id, external_reference, now)
      end

      subscription_attrs = %{
        status: status,
        source: Map.fetch!(attrs, :provider),
        external_reference: external_reference,
        starts_at: Map.get(attrs, :starts_at, now),
        expires_at: Map.get(attrs, :expires_at),
        canceled_at: Map.get(attrs, :canceled_at)
      }

      case Repo.get_by(Subscription, external_reference: external_reference) do
        nil ->
          %Subscription{}
          |> Subscription.create_changeset(user, plan, subscription_attrs)
          |> Repo.insert!()

        %Subscription{} = subscription ->
          subscription
          |> Subscription.create_changeset(user, plan, subscription_attrs)
          |> Repo.update!()
      end
    end)
    |> case do
      {:ok, subscription} -> subscription
      {:error, reason} -> raise inspect(reason)
    end
  end

  defp cancel_other_active_subscriptions!(user_id, external_reference, now) do
    from(s in Subscription,
      where: s.user_id == ^user_id and s.status == "active",
      where: s.external_reference != ^external_reference or is_nil(s.external_reference)
    )
    |> Repo.update_all(set: [status: "canceled", canceled_at: now, updated_at: now])
  end

  defp ensure_playback_slot_available(%User{} = user) do
    case feature_limit_for(user, :concurrent_streams) do
      nil ->
        :ok

      limit ->
        if active_playback_count(user) < limit do
          :ok
        else
          {:error, :concurrent_stream_limit_reached}
        end
    end
  end

  defp cleanup_stale_playback_sessions!(user_id) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -120, :second)
    now = DateTime.utc_now(:second)

    from(ps in PlaybackSession,
      where: ps.user_id == ^user_id,
      where: ps.status == "active",
      where: ps.last_seen_at < ^cutoff
    )
    |> Repo.update_all(set: [status: "ended", ended_at: now, updated_at: now])
  end

  defp playback_session_id do
    "playback:" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end

  defp normalize_provider(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp normalize_provider(provider) when is_binary(provider), do: provider

  defp has_legacy_global_access?(user_id) do
    from(s in active_subscription_query(user_id),
      join: p in assoc(s, :plan),
      where: p.active == true,
      where: p.grants_global_access == true
    )
    |> Repo.exists?()
  end

  defp has_active_feature?(user_id, feature) do
    from(s in active_subscription_query(user_id),
      join: p in assoc(s, :plan),
      join: f in PlanFeature,
      on: f.plan_id == s.plan_id,
      where: p.active == true,
      where: f.feature == ^feature and f.enabled == true
    )
    |> Repo.exists?()
  end

  defp active_subscription_query(user_id) do
    now = DateTime.utc_now()

    from(s in Subscription,
      where: s.user_id == ^user_id and s.status == "active",
      where: is_nil(s.starts_at) or s.starts_at <= ^now,
      where: is_nil(s.expires_at) or s.expires_at > ^now
    )
  end

  defp normalize_feature(feature) when is_atom(feature), do: Atom.to_string(feature)
  defp normalize_feature(feature) when is_binary(feature), do: feature

  defp upsert_plan_feature!(%Plan{} = plan, feature, value) do
    feature = normalize_feature(feature)
    attrs = plan_feature_attrs(plan, feature, value)

    case Repo.get_by(PlanFeature, plan_id: plan.id, feature: feature) do
      nil ->
        %PlanFeature{}
        |> PlanFeature.changeset(attrs)
        |> Repo.insert!()

      %PlanFeature{} = plan_feature ->
        plan_feature
        |> PlanFeature.changeset(attrs)
        |> Repo.update!()
    end
  end

  defp plan_feature_attrs(%Plan{} = plan, feature, value) when is_boolean(value) do
    %{plan_id: plan.id, feature: feature, enabled: value}
  end

  defp plan_feature_attrs(%Plan{} = plan, feature, value) when is_integer(value) do
    %{plan_id: plan.id, feature: feature, enabled: true, limit: value}
  end

  defp plan_feature_attrs(%Plan{} = plan, feature, value) when is_map(value) do
    value = stringify_keys(value)

    %{
      plan_id: plan.id,
      feature: feature,
      enabled: Map.get(value, "enabled", true),
      limit: Map.get(value, "limit"),
      metadata: Map.get(value, "metadata", %{})
    }
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  @doc """
  Finds or creates a manual subscription for a user and plan.
  """
  def ensure_manual_subscription!(%User{} = user, %Plan{} = plan, attrs)
      when is_map(attrs) do
    attrs = Map.merge(%{source: "manual", status: "active"}, attrs)

    external_reference =
      Map.get(attrs, :external_reference) || manual_subscription_reference(user, plan)

    attrs = Map.put(attrs, :external_reference, external_reference)

    case Repo.get_by(Subscription, external_reference: external_reference) do
      nil ->
        %Subscription{}
        |> Subscription.create_changeset(user, plan, attrs)
        |> Repo.insert!()

      %Subscription{} = subscription ->
        attrs = Map.put(attrs, :starts_at, subscription.starts_at)

        subscription
        |> Subscription.create_changeset(user, plan, attrs)
        |> Repo.update!()
    end
  end

  # ---------------------------------------------------------------------------
  # Admin functions
  # ---------------------------------------------------------------------------

  def list_plans do
    from(p in Plan, order_by: [asc: p.inserted_at], preload: [:features])
    |> Repo.all()
  end

  def get_plan!(id), do: Repo.get!(Plan, id)

  def create_plan(attrs) do
    {attrs, features} = split_features(attrs)

    %Plan{}
    |> Plan.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, plan} -> {:ok, sync_plan_features!(plan, features)}
      error -> error
    end
  end

  def update_plan(%Plan{} = plan, attrs) do
    {attrs, features} = split_features(attrs)

    plan
    |> Plan.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, plan} -> {:ok, sync_plan_features!(plan, features)}
      error -> error
    end
  end

  def create_manual_subscription(%User{} = user, %Plan{} = plan, attrs) do
    %Subscription{}
    |> Subscription.create_changeset(user, plan, Map.merge(%{source: "manual"}, attrs))
    |> Repo.insert()
  end

  def cancel_subscription!(%Subscription{} = subscription) do
    subscription
    |> Ecto.Changeset.change(%{
      status: "canceled",
      canceled_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update!()
  end

  def list_subscriptions(opts \\ []) do
    query = from(s in Subscription, preload: [:plan, :user], order_by: [desc: s.inserted_at])

    query =
      case Keyword.get(opts, :user_id) do
        nil -> query
        user_id -> from(s in query, where: s.user_id == ^user_id)
      end

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> from(s in query, where: s.status == ^status)
      end

    Repo.all(query)
  end

  def admin_stats do
    now = DateTime.utc_now()

    %{
      total_users: Repo.aggregate(User, :count),
      active_subscriptions:
        from(s in Subscription, where: s.status == "active")
        |> Repo.aggregate(:count),
      active_plans:
        from(p in Plan, where: p.active == true)
        |> Repo.aggregate(:count),
      monthly_revenue_cents:
        from(s in Subscription,
          join: p in assoc(s, :plan),
          where: s.status == "active",
          where: is_nil(s.expires_at) or s.expires_at > ^now,
          select: coalesce(sum(p.price_cents), 0)
        )
        |> Repo.one()
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp current_plan_attrs(%Plan{} = plan) do
    Map.take(plan, [
      :name,
      :slug,
      :description,
      :price_cents,
      :currency,
      :billing_interval,
      :active,
      :grants_global_access
    ])
  end

  defp split_features(attrs) when is_map(attrs) do
    features = Map.get(attrs, :features) || Map.get(attrs, "features") || %{}

    attrs =
      attrs
      |> Map.delete(:features)
      |> Map.delete("features")

    {attrs, normalize_features(features)}
  end

  defp normalize_features(features) when is_map(features) do
    features
    |> Enum.reject(fn {_feature, value} -> value in [nil, ""] end)
    |> Map.new(fn {feature, value} -> {feature, normalize_feature_value(value)} end)
  end

  defp normalize_features(_features), do: %{}

  defp normalize_feature_value("true"), do: true
  defp normalize_feature_value("false"), do: false

  defp normalize_feature_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> value
    end
  end

  defp normalize_feature_value(value), do: value

  defp manual_subscription_reference(%User{id: user_id}, %Plan{id: plan_id}) do
    "seed:manual:#{user_id}:#{plan_id}"
  end

  defp payment_subscription_reference(provider, nil, %User{id: user_id}, %Plan{id: plan_id}) do
    "billing:#{provider}:#{user_id}:#{plan_id}"
  end

  defp payment_subscription_reference(provider, external_id, _user, _plan) do
    "billing:#{provider}:#{external_id}"
  end

  defp upsert_payment!(%User{} = user, %Plan{} = plan, %Subscription{} = subscription, attrs) do
    payment_attrs =
      attrs
      |> Map.put(:user_id, user.id)
      |> Map.put(:plan_id, plan.id)
      |> Map.put(:subscription_id, subscription.id)

    case existing_by_provider_external(Payment, payment_attrs) do
      nil ->
        %Payment{}
        |> Payment.changeset(payment_attrs)
        |> Repo.insert!()

      %Payment{} = payment ->
        payment
        |> Payment.changeset(payment_attrs)
        |> Repo.update!()
    end
  end

  defp maybe_upsert_invoice!(
         %User{} = user,
         %Plan{} = plan,
         %Subscription{} = subscription,
         attrs,
         now
       ) do
    invoice_attrs = Map.get(attrs, :invoice, %{})

    invoice_attrs =
      %{
        user_id: user.id,
        plan_id: plan.id,
        subscription_id: subscription.id,
        provider: Map.fetch!(attrs, :provider),
        status: Map.get(invoice_attrs, :status, Map.get(attrs, :invoice_status, "paid")),
        external_id: Map.get(invoice_attrs, :external_id, Map.get(attrs, :invoice_external_id)),
        number: Map.get(invoice_attrs, :number, Map.get(attrs, :invoice_number)),
        amount_due_cents:
          Map.get(
            invoice_attrs,
            :amount_due_cents,
            Map.get(attrs, :amount_cents, plan.price_cents)
          ),
        amount_paid_cents:
          Map.get(
            invoice_attrs,
            :amount_paid_cents,
            Map.get(attrs, :amount_cents, plan.price_cents)
          ),
        currency: Map.get(invoice_attrs, :currency, Map.get(attrs, :currency, plan.currency)),
        hosted_invoice_url:
          Map.get(invoice_attrs, :hosted_invoice_url, Map.get(attrs, :hosted_invoice_url)),
        due_at: Map.get(invoice_attrs, :due_at, Map.get(attrs, :invoice_due_at)),
        paid_at: Map.get(invoice_attrs, :paid_at, Map.get(attrs, :paid_at, now)),
        metadata: Map.get(invoice_attrs, :metadata, %{})
      }

    case existing_by_provider_external(Invoice, invoice_attrs) do
      nil ->
        %Invoice{}
        |> Invoice.changeset(invoice_attrs)
        |> Repo.insert!()

      %Invoice{} = invoice ->
        invoice
        |> Invoice.changeset(invoice_attrs)
        |> Repo.update!()
    end
  end

  defp existing_by_provider_external(schema, %{provider: provider, external_id: external_id})
       when is_binary(external_id) and external_id != "" do
    Repo.get_by(schema, provider: provider, external_id: external_id)
  end

  defp existing_by_provider_external(_schema, _attrs), do: nil
end
