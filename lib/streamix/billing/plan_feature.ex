defmodule Streamix.Billing.PlanFeature do
  @moduledoc """
  Feature or limit granted by a billing plan.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Billing.Plan

  schema "plan_features" do
    field :feature, :string
    field :enabled, :boolean, default: true
    field :limit, :integer
    field :metadata, :map, default: %{}

    belongs_to :plan, Plan

    timestamps(type: :utc_datetime)
  end

  @known_features ~w(
    global_catalog
    max_providers
    concurrent_streams
    ai_recommendations
    watch_party
  )

  def known_features, do: @known_features

  def changeset(plan_feature, attrs) do
    plan_feature
    |> cast(attrs, [:plan_id, :feature, :enabled, :limit, :metadata])
    |> validate_required([:plan_id, :feature, :enabled])
    |> validate_inclusion(:feature, @known_features)
    |> validate_number(:limit, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:plan_id)
    |> unique_constraint([:plan_id, :feature])
  end
end
