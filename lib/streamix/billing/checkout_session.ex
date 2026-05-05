defmodule Streamix.Billing.CheckoutSession do
  @moduledoc """
  Provider-agnostic checkout session for self-service plan purchases.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Accounts.User
  alias Streamix.Billing.Plan

  schema "checkout_sessions" do
    field :provider, :string
    field :status, :string, default: "pending"
    field :external_id, :string
    field :checkout_url, :string
    field :success_url, :string
    field :cancel_url, :string
    field :amount_cents, :integer
    field :currency, :string
    field :expires_at, :utc_datetime
    field :metadata, :map, default: %{}

    belongs_to :user, User
    belongs_to :plan, Plan

    timestamps(type: :utc_datetime)
  end

  @statuses ~w(pending open completed expired canceled failed)

  def changeset(checkout_session, attrs) do
    checkout_session
    |> cast(attrs, [
      :user_id,
      :plan_id,
      :provider,
      :status,
      :external_id,
      :checkout_url,
      :success_url,
      :cancel_url,
      :amount_cents,
      :currency,
      :expires_at,
      :metadata
    ])
    |> validate_required([:user_id, :plan_id, :provider, :status, :amount_cents, :currency])
    |> validate_number(:amount_cents, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:plan_id)
    |> unique_constraint([:provider, :external_id])
  end

  def create_changeset(checkout_session, %User{} = user, %Plan{} = plan, attrs) do
    checkout_session
    |> changeset(
      attrs
      |> Map.put(:user_id, user.id)
      |> Map.put(:plan_id, plan.id)
      |> Map.put(:amount_cents, plan.price_cents)
      |> Map.put(:currency, plan.currency)
    )
  end
end
