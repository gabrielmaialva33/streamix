defmodule Streamix.Accounts.Role do
  @moduledoc """
  Role schema for user authorization.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(admin customer moderator)

  schema "roles" do
    field :name, :string
    field :description, :string

    has_many :users, Streamix.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> validate_inclusion(:name, @roles)
    |> unique_constraint(:name)
  end

  def allowed_roles, do: @roles
end
