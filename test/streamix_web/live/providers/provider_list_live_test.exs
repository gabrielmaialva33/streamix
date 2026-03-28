defmodule StreamixWeb.Providers.ProviderListLiveTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Streamix.IptvFixtures

  describe "edit route" do
    setup :register_and_log_in_user

    test "loads the selected provider when editing by provider_id route param", %{
      conn: conn,
      user: user
    } do
      provider = provider_fixture(user, %{name: "Meu Provider"})

      {:ok, view, _html} = live(conn, ~p"/providers/#{provider.id}/edit")

      assert has_element?(view, "#provider-modal")
      assert has_element?(view, "#provider-form")
      assert render(view) =~ "Editar Provedor"
      assert render(view) =~ "Meu Provider"
    end
  end
end
