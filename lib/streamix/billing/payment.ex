defmodule Streamix.Billing.Payment do
  @moduledoc """
  Payment captured from a billing provider webhook or admin import.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Billing.{Plan, Subscription}

  schema "payments" do
    field :user_id, :id
    field :user_email, :string, virtual: true
    field :provider, :string
    field :status, :string
    field :external_id, :string
    field :amount_cents, :integer
    field :currency, :string
    field :paid_at, :utc_datetime
    field :failure_reason, :string
    field :raw_event, :map, default: %{}

    belongs_to :plan, Plan
    belongs_to :subscription, Subscription

    timestamps(type: :utc_datetime)
  end

  @statuses ~w(pending paid failed refunded canceled)

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [
      :user_id,
      :plan_id,
      :subscription_id,
      :provider,
      :status,
      :external_id,
      :amount_cents,
      :currency,
      :paid_at,
      :failure_reason,
      :raw_event
    ])
    |> validate_required([:user_id, :plan_id, :provider, :status, :amount_cents, :currency])
    |> validate_number(:amount_cents, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:plan_id)
    |> foreign_key_constraint(:subscription_id)
    |> unique_constraint([:provider, :external_id])
  end
end
