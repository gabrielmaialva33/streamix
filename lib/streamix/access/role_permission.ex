defmodule Streamix.Access.RolePermission do
  @moduledoc """
  Join table for role-based permissions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Access.Permission

  schema "role_permissions" do
    field :role_id, :id
    belongs_to :permission, Permission
  end

  def changeset(role_permission, attrs) do
    role_permission
    |> cast(attrs, [:role_id, :permission_id])
    |> validate_required([:role_id, :permission_id])
    |> unique_constraint([:role_id, :permission_id])
    |> foreign_key_constraint(:role_id)
    |> assoc_constraint(:permission)
  end
end
