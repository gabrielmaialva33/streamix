defmodule Streamix.Billing.Entitlements do
  @moduledoc """
  Subscription-backed access checks and feature limits.
  """

  import Ecto.Query, warn: false

  alias Streamix.Accounts.User
  alias Streamix.Billing.{PlanFeature, Subscription}
  alias Streamix.Repo

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
end
