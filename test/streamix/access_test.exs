defmodule Streamix.AccessTest do
  use Streamix.DataCase, async: true

  alias Streamix.Access
  alias Streamix.AccountsFixtures
  alias Streamix.IptvFixtures

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
end
