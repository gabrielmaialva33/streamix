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
end
