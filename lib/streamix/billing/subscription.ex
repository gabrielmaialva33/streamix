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

  @allowed_statuses ~w(active pending canceled expired)

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :status,
      :starts_at,
      :expires_at,
      :canceled_at,
      :source,
      :external_reference
    ])
    |> validate_required([:status])
    |> validate_inclusion(:status, @allowed_statuses)
    |> validate_start_before_expiration()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:plan_id)
  end

  def create_changeset(subscription, user, plan, attrs) do
    subscription
    |> changeset(attrs)
    |> put_change(:user_id, user.id)
    |> put_change(:plan_id, plan.id)
    |> validate_required([:user_id, :plan_id, :status])
  end

  defp validate_start_before_expiration(changeset) do
    starts_at = get_field(changeset, :starts_at)
    expires_at = get_field(changeset, :expires_at)

    if is_nil(starts_at) or is_nil(expires_at) do
      changeset
    else
      case DateTime.compare(starts_at, expires_at) do
        :lt -> changeset
        :gt -> add_error(changeset, :expires_at, "must be after starts_at")
        :eq -> add_error(changeset, :expires_at, "must be after starts_at")
      end
    end
  end
end
