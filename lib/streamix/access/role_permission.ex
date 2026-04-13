defmodule Streamix.Access.RolePermission do
  @moduledoc """
  Join table for role-based permissions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Access.Permission
  alias Streamix.Accounts.Role

  schema "role_permissions" do
    belongs_to :role, Role
    belongs_to :permission, Permission
  end

  def changeset(role_permission, attrs) do
    role_permission
    |> cast(attrs, [:role_id, :permission_id])
    |> validate_required([:role_id, :permission_id])
    |> unique_constraint([:role_id, :permission_id])
    |> assoc_constraint(:role)
    |> assoc_constraint(:permission)
  end
end
