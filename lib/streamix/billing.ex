defmodule Streamix.Billing do
  @moduledoc """
  Billing context for plans and subscriptions.
  """

  import Ecto.Query, warn: false

  alias Streamix.Accounts.User
  alias Streamix.Billing.Plan
  alias Streamix.Billing.Subscription
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

    case Repo.get_by(Plan, slug: slug) do
      nil ->
        %Plan{}
        |> Plan.changeset(attrs)
        |> Repo.insert!()

      %Plan{} = plan ->
        plan
        |> Plan.changeset(Map.merge(current_plan_attrs(plan), attrs))
        |> Repo.update!()
    end
  end

  def subscribed?(%User{id: user_id}) do
    now = DateTime.utc_now()

    from(s in Subscription,
      join: p in assoc(s, :plan),
      where: s.user_id == ^user_id and s.status == "active",
      where: p.active == true and p.grants_global_access == true,
      where: is_nil(s.starts_at) or s.starts_at <= ^now,
      where: is_nil(s.expires_at) or s.expires_at > ^now
    )
    |> Repo.exists?()
  end

  def subscribed?(_user), do: false

  def active_subscription_for_user(%User{id: user_id}) do
    now = DateTime.utc_now()

    from(s in Subscription,
      join: p in assoc(s, :plan),
      where: s.user_id == ^user_id and s.status == "active",
      where: p.active == true and p.grants_global_access == true,
      where: is_nil(s.starts_at) or s.starts_at <= ^now,
      where: is_nil(s.expires_at) or s.expires_at > ^now,
      preload: [plan: p],
      order_by: [desc: s.inserted_at, desc: s.id],
      limit: 1
    )
    |> Repo.one()
  end

  def active_subscription_for_user(_user), do: nil

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
    from(p in Plan, order_by: [asc: p.inserted_at])
    |> Repo.all()
  end

  def get_plan!(id), do: Repo.get!(Plan, id)

  def create_plan(attrs) do
    %Plan{}
    |> Plan.changeset(attrs)
    |> Repo.insert()
  end

  def update_plan(%Plan{} = plan, attrs) do
    plan
    |> Plan.changeset(attrs)
    |> Repo.update()
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

  defp manual_subscription_reference(%User{id: user_id}, %Plan{id: plan_id}) do
    "seed:manual:#{user_id}:#{plan_id}"
  end
end
