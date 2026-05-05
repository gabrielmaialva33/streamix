defmodule Streamix.Billing.BillingCustomer do
  @moduledoc """
  External payment provider customer linked to a Streamix user.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Accounts.User

  schema "billing_customers" do
    field :provider, :string
    field :external_id, :string
    field :metadata, :map, default: %{}

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def changeset(customer, attrs) do
    customer
    |> cast(attrs, [:user_id, :provider, :external_id, :metadata])
    |> validate_required([:user_id, :provider, :external_id])
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:provider, :external_id])
    |> unique_constraint([:user_id, :provider])
  end
end
