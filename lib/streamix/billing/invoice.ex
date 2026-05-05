defmodule Streamix.Billing.Invoice do
  @moduledoc """
  Invoice history imported from a payment provider.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Accounts.User
  alias Streamix.Billing.{Plan, Subscription}

  schema "invoices" do
    field :provider, :string
    field :status, :string
    field :external_id, :string
    field :number, :string
    field :amount_due_cents, :integer
    field :amount_paid_cents, :integer, default: 0
    field :currency, :string
    field :hosted_invoice_url, :string
    field :due_at, :utc_datetime
    field :paid_at, :utc_datetime
    field :metadata, :map, default: %{}

    belongs_to :user, User
    belongs_to :plan, Plan
    belongs_to :subscription, Subscription

    timestamps(type: :utc_datetime)
  end

  @statuses ~w(draft open paid void uncollectible)

  def changeset(invoice, attrs) do
    invoice
    |> cast(attrs, [
      :user_id,
      :plan_id,
      :subscription_id,
      :provider,
      :status,
      :external_id,
      :number,
      :amount_due_cents,
      :amount_paid_cents,
      :currency,
      :hosted_invoice_url,
      :due_at,
      :paid_at,
      :metadata
    ])
    |> validate_required([:user_id, :plan_id, :provider, :status, :amount_due_cents, :currency])
    |> validate_number(:amount_due_cents, greater_than_or_equal_to: 0)
    |> validate_number(:amount_paid_cents, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:plan_id)
    |> foreign_key_constraint(:subscription_id)
    |> unique_constraint([:provider, :external_id])
  end
end
