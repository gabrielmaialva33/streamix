defmodule Streamix.Access.Permission do
  @moduledoc """
  Permission definitions that can be granted to roles or individual users.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "permissions" do
    field :name, :string
    field :description, :string

    has_many :role_permissions, Streamix.Access.RolePermission
    has_many :user_permissions, Streamix.Access.UserPermission

    timestamps(type: :utc_datetime)
  end

  def changeset(permission, attrs) do
    permission
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
