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
