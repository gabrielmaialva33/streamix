defmodule Streamix.AccessTest do
  use Streamix.DataCase, async: true

  alias Streamix.Access
  alias Streamix.Access.{Permission, RolePermission, UserPermission}
  alias Streamix.AccountsFixtures
  alias Streamix.Iptv.LiveChannel
  alias Streamix.IptvFixtures

  defp permission_fixture(attrs \\ %{}) do
    params =
      Enum.into(attrs, %{
        name: "play_global_content",
        description: "Allows playing global content"
      })

    case Repo.get_by(Permission, name: params.name) do
      nil ->
        %Permission{}
        |> Permission.changeset(params)
        |> Repo.insert!()

      %Permission{} = permission ->
        permission
    end
  end

  defp admin_user_fixture(attrs \\ %{}) do
    AccountsFixtures.admin_user_fixture(attrs)
  end

  defp user_fixture(attrs \\ %{}) do
    AccountsFixtures.user_fixture(attrs)
  end

  defp provider_fixture(user, attrs) do
    IptvFixtures.provider_fixture(user, attrs)
  end

  test "admin can play global content without subscription" do
    admin = admin_user_fixture()
    provider = provider_fixture(admin, %{is_system: true, visibility: "global"})

    assert Access.can_play_global_content?(admin, provider)
  end

  test "customer cannot play global content without subscription" do
    user = user_fixture()
    provider = provider_fixture(user, %{is_system: true, visibility: "global"})

    refute Access.can_play_global_content?(user, provider)
  end

  test "explicit user permission grants play_global_content" do
    user = user_fixture()
    provider = provider_fixture(user, %{is_system: true, visibility: "global"})
    permission = permission_fixture()

    %UserPermission{}
    |> UserPermission.changeset(%{user_id: user.id, permission_id: permission.id})
    |> Repo.insert!()

    assert Access.can_play_global_content?(user, provider)
  end

  test "explicit role permission grants play_global_content" do
    user = user_fixture()
    provider = provider_fixture(user, %{is_system: true, visibility: "global"})
    permission = permission_fixture()

    %RolePermission{}
    |> RolePermission.changeset(%{role: "customer", permission_id: permission.id})
    |> Repo.insert!()

    assert Access.can_play_global_content?(user, provider)
  end

  test "global content with provider_id but without preloaded provider is still blocked for customer without subscription or permission" do
    user = user_fixture()
    provider = provider_fixture(user, %{is_system: true, visibility: "global"})
    content = %LiveChannel{provider_id: provider.id}

    refute Access.can_play_global_content?(user, content)
  end

  test "private or public content with provider_id but without preloaded provider is still allowed for customer without subscription or permission" do
    owner = user_fixture()
    user = user_fixture()

    for visibility <- [:private, :public] do
      provider = provider_fixture(owner, %{visibility: visibility})
      content = %LiveChannel{provider_id: provider.id}

      assert Access.can_play_global_content?(user, content)
    end
  end

  test "permission_by_name/1 returns the persisted permission" do
    permission =
      permission_fixture(
        name: "custom_permission_#{System.unique_integer([:positive])}",
        description: "Custom"
      )

    fetched_permission = Access.permission_by_name(permission.name)

    assert %Permission{description: "Custom"} = fetched_permission
    assert fetched_permission.name == permission.name
    assert fetched_permission.id == permission.id
  end

  test "ensure_permission!/1 does not duplicate a permission by name" do
    permission_name = "play_global_content_#{System.unique_integer([:positive])}"

    first_permission = Access.ensure_permission!(permission_name)
    second_permission = Access.ensure_permission!(permission_name)

    assert first_permission.id == second_permission.id
    assert first_permission.name == permission_name

    assert Repo.aggregate(from(p in Permission, where: p.name == ^permission_name), :count, :id) ==
             1
  end

  test "ensure_role_permissions!/2 does not duplicate role permission links" do
    permission_name = "play_global_content_role_#{System.unique_integer([:positive])}"
    Access.ensure_permission!(permission_name)

    first_role_permissions = Access.ensure_role_permissions!("admin", [permission_name])
    second_role_permissions = Access.ensure_role_permissions!("admin", [permission_name])

    assert [%RolePermission{id: first_id, role: "admin"}] = first_role_permissions
    assert [%RolePermission{id: second_id, role: "admin"}] = second_role_permissions
    assert first_id == second_id

    assert Repo.aggregate(
             from(rp in RolePermission,
               join: p in assoc(rp, :permission),
               where: rp.role == "admin" and p.name == ^permission_name
             ),
             :count,
             :id
           ) == 1
  end
end
