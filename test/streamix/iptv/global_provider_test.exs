defmodule Streamix.Iptv.GlobalProviderTest do
  use Streamix.DataCase, async: false

  import Streamix.AccountsFixtures

  alias Streamix.Iptv.GlobalProvider
  alias Streamix.Iptv.Provider

  setup do
    original_config = Application.get_env(:streamix, :global_provider)

    config = [
      enabled: true,
      name: "Seed Global #{System.unique_integer([:positive])}",
      url: "http://global-#{System.unique_integer([:positive])}.example.com",
      username: "global_user",
      password: "global_pass"
    ]

    Application.put_env(:streamix, :global_provider, config)

    on_exit(fn ->
      case original_config do
        nil -> Application.delete_env(:streamix, :global_provider)
        config -> Application.put_env(:streamix, :global_provider, config)
      end
    end)

    %{config: config}
  end

  test "ensure_exists!/1 links a new global provider to the seed admin", %{config: config} do
    admin = admin_user_fixture()

    assert {:ok, %Provider{} = provider} = GlobalProvider.ensure_exists!(admin)
    assert provider.user_id == admin.id
    assert provider.name == config[:name]
    assert provider.visibility == :global
    assert provider.is_system
  end

  test "ensure_exists!/1 relinks an existing global provider to the seed admin", %{config: config} do
    previous_owner = admin_user_fixture()
    seed_admin = admin_user_fixture()

    {:ok, existing_provider} =
      %Provider{user_id: previous_owner.id}
      |> Provider.changeset(%{
        name: config[:name],
        url: config[:url],
        username: config[:username],
        password: config[:password],
        is_system: true,
        visibility: :global,
        is_active: true
      })
      |> Repo.insert()

    assert {:ok, %Provider{} = provider} = GlobalProvider.ensure_exists!(seed_admin)
    assert provider.id == existing_provider.id
    assert provider.user_id == seed_admin.id
  end
end
