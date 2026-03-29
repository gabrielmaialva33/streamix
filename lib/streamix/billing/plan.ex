defmodule Streamix.Billing.Plan do
  @moduledoc """
  Schema for billing plans.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "plans" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :price_cents, :integer
    field :currency, :string
    field :billing_interval, :string
    field :active, :boolean, default: true
    field :grants_global_access, :boolean, default: true

    has_many :subscriptions, Streamix.Billing.Subscription

    timestamps(type: :utc_datetime)
  end

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :name,
      :slug,
      :description,
      :price_cents,
      :currency,
      :billing_interval,
      :active,
      :grants_global_access
    ])
    |> validate_required([
      :name,
      :slug,
      :price_cents,
      :currency,
      :billing_interval
    ])
    |> unique_constraint(:slug)
  end
end
