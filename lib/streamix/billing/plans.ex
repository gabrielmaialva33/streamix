defmodule Streamix.Billing.Plans do
  @moduledoc """
  Plan catalog and plan feature maintenance.
  """

  import Ecto.Query, warn: false

  alias Streamix.Billing.{Plan, PlanFeature}
  alias Streamix.Repo

  def list_active_plans do
    from(p in Plan,
      where: p.active == true,
      order_by: [asc: p.price_cents, asc: p.inserted_at]
    )
    |> Repo.all()
  end

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

  def sync_plan_features!(%Plan{} = plan, features) when is_map(features) do
    Enum.each(features, fn {feature, value} ->
      upsert_plan_feature!(plan, feature, value)
    end)

    Repo.preload(plan, :features, force: true)
  end

  def sync_plan_features!(%Plan{} = plan, _features), do: plan

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

  def get_plan_by_stripe_price_id(price_id) when is_binary(price_id) and price_id != "" do
    Repo.get_by(Plan, stripe_price_id: price_id)
  end

  def get_plan_by_stripe_price_id(_price_id), do: nil

  defp current_plan_attrs(%Plan{} = plan) do
    Map.take(plan, [
      :name,
      :slug,
      :description,
      :price_cents,
      :currency,
      :billing_interval,
      :stripe_price_id,
      :trial_days,
      :active,
      :grants_global_access
    ])
  end

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

  defp normalize_feature(feature) when is_atom(feature), do: Atom.to_string(feature)
  defp normalize_feature(feature) when is_binary(feature), do: feature

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
