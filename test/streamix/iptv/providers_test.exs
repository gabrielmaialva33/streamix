defmodule Streamix.Iptv.ProvidersTest do
  use Streamix.DataCase, async: true

  alias Streamix.{Billing, Iptv}

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  describe "provider ownership" do
    test "create_provider/2 assigns ownership server-side" do
      user = user_fixture()

      assert {:ok, provider} = Iptv.create_provider(user.id, valid_provider_attrs())
      assert provider.user_id == user.id
    end

    test "create_provider/2 cannot promote a user provider to global visibility" do
      user = user_fixture()

      attrs =
        valid_provider_attrs(%{
          is_system: true,
          provider_type: :gindex,
          visibility: :global,
          sync_status: "completed",
          server_info: %{"forged" => true}
        })

      assert {:error, changeset} = Iptv.create_provider(user.id, attrs)
      assert "is invalid" in errors_on(changeset).visibility

      safe_attrs = Map.delete(attrs, :visibility)
      assert {:ok, provider} = Iptv.create_provider(user.id, safe_attrs)
      refute provider.is_system
      assert provider.provider_type == :xtream
      assert provider.visibility == :private
      assert provider.sync_status == "idle"
      assert is_nil(provider.server_info)
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

    test "update_user_provider/3 enforces ownership and privileged fields" do
      owner = user_fixture()
      other_user = user_fixture()
      provider = provider_fixture(owner)

      assert {:error, changeset} =
               Iptv.update_user_provider(other_user.id, provider, %{name: "Stolen"})

      assert "provider does not belong to current user" in errors_on(changeset).base

      assert {:error, changeset} =
               Iptv.update_user_provider(owner.id, provider, %{
                 name: "Safe rename",
                 is_system: true,
                 provider_type: :gindex,
                 visibility: :global
               })

      assert "is invalid" in errors_on(changeset).visibility

      assert {:ok, updated} =
               Iptv.update_user_provider(owner.id, provider, %{
                 name: "Safe rename",
                 is_system: true,
                 provider_type: :gindex
               })

      assert updated.name == "Safe rename"
      refute updated.is_system
      assert updated.provider_type == :xtream
      assert updated.visibility == :private
    end

    test "create_provider/2 enforces max_providers from the active plan" do
      user = user_fixture()

      plan =
        Billing.ensure_plan!(%{
          name: "Provider Limited",
          slug: "provider-limited",
          description: "One provider",
          price_cents: 999,
          currency: "BRL",
          billing_interval: "month",
          active: true,
          grants_global_access: false,
          features: %{max_providers: 1}
        })

      Billing.ensure_manual_subscription!(user, plan, %{
        status: "active",
        external_reference: "test:max-providers",
        starts_at: DateTime.utc_now(:second)
      })

      assert {:ok, _provider} = Iptv.create_provider(user.id, valid_provider_attrs())

      assert {:error, changeset} =
               Iptv.create_provider(
                 user.id,
                 valid_provider_attrs(%{name: "Second", username: "second"})
               )

      assert "provider limit reached for current plan" in errors_on(changeset).base
    end
  end
end
