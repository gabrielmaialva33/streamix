defmodule Streamix.Iptv.ProvidersTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  describe "provider ownership" do
    test "create_provider/2 assigns ownership server-side" do
      user = user_fixture()

      assert {:ok, provider} = Iptv.create_provider(user.id, valid_provider_attrs())
      assert provider.user_id == user.id
    end

    test "create_provider/1 rejects caller-controlled ownership for non-system providers" do
      user = user_fixture()

      assert {:error, changeset} =
               Iptv.create_provider(valid_provider_attrs(%{user_id: user.id}))

      assert "can't be blank" in errors_on(changeset).user_id
    end

    test "update_provider/2 does not allow ownership changes" do
      owner = user_fixture()
      other_user = user_fixture()
      provider = provider_fixture(owner)

      assert {:ok, updated_provider} =
               Iptv.update_provider(provider, %{name: "Renamed", user_id: other_user.id})

      assert updated_provider.name == "Renamed"
      assert updated_provider.user_id == owner.id
    end
  end
end
