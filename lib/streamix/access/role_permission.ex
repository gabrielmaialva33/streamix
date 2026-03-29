defmodule Streamix.Access.RolePermission do
  @moduledoc """
  Join table for role-based permissions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Access.Permission

  schema "role_permissions" do
    field :role, :string

    belongs_to :permission, Permission
  end

  def changeset(role_permission, attrs) do
    role_permission
    |> cast(attrs, [:role, :permission_id])
    |> validate_required([:role, :permission_id])
    |> unique_constraint([:role, :permission_id])
    |> foreign_key_constraint(:permission_id)
  end
end
