defmodule Streamix.Iptv.ProvidersFacadeTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv
  alias Streamix.Iptv.{Provider, ProviderDrive}

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

  describe "GIndex synchronization boundary" do
    test "projects only the provider data required by GIndex" do
      provider =
        global_provider_fixture(%{
          name: "GIndex Boundary",
          provider_type: :gindex,
          gindex_url: "https://sync.gindex.example"
        })

      %ProviderDrive{}
      |> ProviderDrive.changeset(%{
        provider_id: provider.id,
        name: "Movies",
        drive_type: "movies",
        metadata: %{"path" => "/1:/Movies/"}
      })
      |> Repo.insert!()

      assert {:ok, source} = Iptv.gindex_sync_source(provider)

      assert source == %{
               provider_id: provider.id,
               name: "GIndex Boundary",
               base_url: "https://sync.gindex.example",
               drives: [%{kind: "movies", metadata: %{"path" => "/1:/Movies/"}}]
             }

      refute Map.has_key?(source, :password)
      refute Map.has_key?(source, :username)
    end

    test "rejects non-GIndex providers and scopes runtime updates by adapter" do
      user = user_fixture()
      xtream_provider = provider_fixture(user)

      assert {:error, :not_gindex_provider} = Iptv.gindex_sync_source(xtream_provider)

      assert {:error, :gindex_provider_not_found} =
               Iptv.update_gindex_sync(xtream_provider.id, %{sync_status: "syncing"})

      gindex_provider = global_provider_fixture(%{provider_type: :gindex})

      assert :ok =
               Iptv.update_gindex_sync(gindex_provider.id, %{
                 sync_status: "completed",
                 movies_count: 12,
                 series_count: 7
               })

      updated = Iptv.get_provider!(gindex_provider.id)
      assert updated.sync_status == "completed"
      assert updated.movies_count == 12
      assert updated.series_count == 7

      assert {:error, {:invalid_gindex_sync_fields, [:unknown_count]}} =
               Iptv.update_gindex_sync(gindex_provider.id, %{unknown_count: 99})
    end
  end

  describe "Torrent synchronization boundary" do
    test "projects only the provider identity required by Torrent" do
      provider =
        global_provider_fixture(%{
          name: "Torrent Boundary",
          provider_type: :torrent,
          url: "torrent://boundary"
        })

      assert {:ok, source} = Iptv.torrent_sync_source(provider)
      assert source == %{provider_id: provider.id, name: "Torrent Boundary"}
      assert Iptv.get_torrent_provider_ref() == %{id: provider.id, name: "Torrent Boundary"}

      refute Map.has_key?(source, :password)
      refute Map.has_key?(source, :username)
    end

    test "rejects other adapters and scopes runtime updates to Torrent" do
      user = user_fixture()
      xtream_provider = provider_fixture(user)

      assert {:error, :not_torrent_provider} = Iptv.torrent_sync_source(xtream_provider)

      assert {:error, :torrent_provider_not_found} =
               Iptv.update_torrent_sync(xtream_provider.id, %{sync_status: "syncing"})

      torrent_provider =
        global_provider_fixture(%{
          provider_type: :torrent,
          url: "torrent://sync-boundary"
        })

      assert :ok =
               Iptv.update_torrent_sync(torrent_provider.id, %{
                 sync_status: "completed",
                 movies_count: 42
               })

      updated = Iptv.get_provider!(torrent_provider.id)
      assert updated.sync_status == "completed"
      assert updated.movies_count == 42

      assert {:error, {:invalid_torrent_sync_fields, [:series_count]}} =
               Iptv.update_torrent_sync(torrent_provider.id, %{series_count: 1})
    end
  end
end
