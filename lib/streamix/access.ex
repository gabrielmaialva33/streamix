defmodule Streamix.Access do
  @moduledoc """
  Central authorization helpers for premium and permission-gated content.
  """

  import Ecto.Query, warn: false

  alias Streamix.Access.{Permission, RolePermission, UserPermission}
  alias Streamix.Accounts
  alias Streamix.Accounts.User
  alias Streamix.Billing
  alias Streamix.Iptv
  alias Streamix.Iptv.Provider
  alias Streamix.Repo

  def can_play_global_content?(user, provider_or_content) do
    admin?(user) or
      subscribed?(user) or
      explicitly_permitted?(user, "play_global_content") or
      not global_content?(provider_or_content)
  end

  def global_content?(%{provider_id: provider_id, provider: %Ecto.Association.NotLoaded{}})
      when is_integer(provider_id) do
    case Iptv.get_provider(provider_id) do
      %Provider{} = provider -> provider_global_system?(provider)
      _ -> false
    end
  end

  def global_content?(%{provider_id: _provider_id, provider: provider}) when is_map(provider) do
    provider_global_system?(provider)
  end

  def global_content?(%{is_system: _} = provider), do: provider_global_system?(provider)

  def global_content?(%{provider: provider}) when is_map(provider),
    do: provider_global_system?(provider)

  def global_content?(_resource), do: false

  def admin?(%User{} = user), do: Accounts.admin?(user)
  def admin?(_user), do: false

  def subscribed?(%User{} = user), do: Billing.subscribed?(user)
  def subscribed?(_user), do: false

  def explicitly_permitted?(%User{id: user_id, role: role}, permission_name)
      when is_binary(permission_name) do
    permission_exists_for_user?(user_id, permission_name) or
      permission_exists_for_role?(role, permission_name)
  end

  def explicitly_permitted?(_user, _permission_name), do: false

  def permission_by_name(name) when is_binary(name) do
    from(p in Permission, where: p.name == ^name)
    |> Repo.one()
  end

  def permission_by_name(_name), do: nil

  @doc """
  Finds or creates a permission keyed by name.
  """
  def ensure_permission!(name) when is_binary(name) do
    case Repo.get_by(Permission, name: name) do
      nil ->
        %Permission{}
        |> Permission.changeset(%{name: name})
        |> Repo.insert!()

      %Permission{} = permission ->
        permission
    end
  end

  def ensure_permission!(%{name: name}) when is_binary(name), do: ensure_permission!(name)

  @doc """
  Finds or creates role permissions for the given role and permissions.
  """
  def ensure_role_permissions!(role, permissions)
      when is_binary(role) and is_list(permissions) do
    permissions
    |> Enum.map(&ensure_permission_reference!/1)
    |> Enum.map(&ensure_role_permission_for_permission!(role, &1))
  end

  defp permission_exists_for_user?(user_id, permission_name) do
    from(up in UserPermission,
      join: p in assoc(up, :permission),
      where: up.user_id == ^user_id and p.name == ^permission_name,
      select: true,
      limit: 1
    )
    |> Repo.exists?()
  end

  defp permission_exists_for_role?(role, permission_name) when is_binary(role) do
    from(rp in RolePermission,
      join: p in assoc(rp, :permission),
      where: rp.role == ^role and p.name == ^permission_name,
      select: true,
      limit: 1
    )
    |> Repo.exists?()
  end

  defp permission_exists_for_role?(_role, _permission_name), do: false

  defp provider_global_system?(provider) do
    Map.get(provider, :is_system) == true or Map.get(provider, :visibility) in [:global, "global"]
  end

  defp ensure_permission_reference!(%Permission{} = permission), do: permission

  defp ensure_permission_reference!(name) when is_binary(name) do
    ensure_permission!(name)
  end

  defp ensure_role_permission_for_permission!(role, %Permission{id: permission_id}) do
    case Repo.get_by(RolePermission, role: role, permission_id: permission_id) do
      nil ->
        %RolePermission{}
        |> RolePermission.changeset(%{role: role, permission_id: permission_id})
        |> Repo.insert!()

      %RolePermission{} = role_permission ->
        role_permission
    end
  end
end
