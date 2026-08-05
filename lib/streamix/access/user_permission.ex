defmodule Streamix.Access.UserPermission do
  @moduledoc """
  Join table for user-specific permissions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Access.Permission

  schema "user_permissions" do
    field :user_id, :id
    belongs_to :permission, Permission
  end

  def changeset(user_permission, attrs) do
    user_permission
    |> cast(attrs, [:user_id, :permission_id])
    |> validate_required([:user_id, :permission_id])
    |> unique_constraint([:user_id, :permission_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:permission_id)
  end
end
