defmodule Streamix.Billing.Subscription do
  @moduledoc """
  Schema for user subscriptions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Accounts.User
  alias Streamix.Billing.Plan

  schema "subscriptions" do
    field :status, :string
    field :starts_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :canceled_at, :utc_datetime
    field :source, :string
    field :external_reference, :string

    belongs_to :user, User
    belongs_to :plan, Plan

    timestamps(type: :utc_datetime)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :user_id,
      :plan_id,
      :status,
      :starts_at,
      :expires_at,
      :canceled_at,
      :source,
      :external_reference
    ])
    |> validate_required([:user_id, :plan_id, :status])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:plan_id)
  end
end
