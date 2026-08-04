defmodule Streamix.Iptv.ProvidersFacadeTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv
  alias Streamix.Iptv.Provider

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  # =============================================================================
  # Providers
  # =============================================================================

  describe "list_providers/1" do
    test "returns all providers for a user ordered by name" do
      user = user_fixture()
      provider_fixture(user, %{name: "Zebra Provider"})
      provider_fixture(user, %{name: "Alpha Provider"})
      provider_fixture(user, %{name: "Beta Provider"})

      providers = Iptv.list_providers(user.id)

      assert length(providers) == 3

      assert Enum.map(providers, & &1.name) == [
               "Alpha Provider",
               "Beta Provider",
               "Zebra Provider"
             ]
    end

    test "returns empty list for user with no providers" do
      user = user_fixture()
      assert Iptv.list_providers(user.id) == []
    end

    test "does not return other users' providers" do
      user1 = user_fixture()
      user2 = user_fixture()
      provider_fixture(user1, %{name: "User1 Provider"})
      provider_fixture(user2, %{name: "User2 Provider"})

      providers = Iptv.list_providers(user1.id)

      assert length(providers) == 1
      assert hd(providers).name == "User1 Provider"
    end
  end

  describe "get_provider!/1" do
    test "returns the provider with given id" do
      user = user_fixture()
      provider = provider_fixture(user)

      assert Iptv.get_provider!(provider.id).id == provider.id
    end

    test "raises if provider does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Iptv.get_provider!(0)
      end
    end
  end

  describe "get_provider/1" do
    test "returns the provider with given id" do
      user = user_fixture()
      provider = provider_fixture(user)

      assert Iptv.get_provider(provider.id).id == provider.id
    end

    test "returns nil if provider does not exist" do
      assert is_nil(Iptv.get_provider(0))
    end
  end

  describe "get_user_provider/2" do
    test "returns provider if it belongs to user" do
      user = user_fixture()
      provider = provider_fixture(user)

      result = Iptv.get_user_provider(user.id, provider.id)

      assert result.id == provider.id
    end

    test "returns nil if provider belongs to different user" do
      user1 = user_fixture()
      user2 = user_fixture()
      provider = provider_fixture(user1)

      assert is_nil(Iptv.get_user_provider(user2.id, provider.id))
    end

    test "returns nil if provider does not exist" do
      user = user_fixture()
      assert is_nil(Iptv.get_user_provider(user.id, 0))
    end
  end

  describe "create_provider/2" do
    test "creates a provider with valid data" do
      user = user_fixture()

      attrs = %{
        name: "Test Provider",
        url: "http://provider.example.com",
        username: "user",
        password: "pass"
      }

      assert {:ok, %Provider{} = provider} = Iptv.create_provider(user.id, attrs)
      assert provider.name == "Test Provider"
      assert provider.url == "http://provider.example.com"
      assert provider.username == "user"
      assert provider.password == "pass"
      assert provider.user_id == user.id
      assert provider.is_active == true
      assert provider.sync_status == "idle"
      assert provider.live_channels_count == 0
    end

    test "returns error changeset with invalid data" do
      user = user_fixture()
      assert {:error, %Ecto.Changeset{}} = Iptv.create_provider(user.id, %{})
    end

    test "validates required fields" do
      user = user_fixture()
      assert {:error, changeset} = Iptv.create_provider(user.id, %{})

      assert "can't be blank" in errors_on(changeset).name
      assert "can't be blank" in errors_on(changeset).url
      assert "can't be blank" in errors_on(changeset).username
      assert "can't be blank" in errors_on(changeset).password
    end

    test "validates URL format" do
      user = user_fixture()

      attrs = valid_provider_attrs(%{url: "not-a-url"})
      assert {:error, changeset} = Iptv.create_provider(user.id, attrs)
      assert "must be a valid HTTP/HTTPS URL" in errors_on(changeset).url

      for invalid_url <- ["http:", "http://provider.example.com:bad", "https://u:p@example.com"] do
        attrs = valid_provider_attrs(%{url: invalid_url})
        assert {:error, changeset} = Iptv.create_provider(user.id, attrs)
        assert "must be a valid HTTP/HTTPS URL" in errors_on(changeset).url
      end
    end

    test "enforces unique constraint on user_id, url, username" do
      user = user_fixture()
      provider = provider_fixture(user)

      duplicate_attrs = %{
        name: "Duplicate",
        url: provider.url,
        username: provider.username,
        password: "different"
      }

      assert {:error, changeset} = Iptv.create_provider(user.id, duplicate_attrs)
      assert "has already been taken" in errors_on(changeset).user_id
    end
  end

  describe "update_provider/2" do
    test "updates the provider with valid data" do
      user = user_fixture()
      provider = provider_fixture(user)

      assert {:ok, updated} = Iptv.update_provider(provider, %{name: "Updated Name"})
      assert updated.name == "Updated Name"
    end

    test "returns error changeset with invalid data" do
      user = user_fixture()
      provider = provider_fixture(user)

      assert {:error, changeset} = Iptv.update_provider(provider, %{url: "invalid"})
      assert "must be a valid HTTP/HTTPS URL" in errors_on(changeset).url
    end
  end

  describe "delete_provider/1" do
    test "deletes the provider" do
      user = user_fixture()
      provider = provider_fixture(user)

      assert {:ok, %Provider{}} = Iptv.delete_provider(provider)
      assert is_nil(Iptv.get_provider(provider.id))
    end
  end
end
