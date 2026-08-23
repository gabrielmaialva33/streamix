defmodule StreamixWeb.Providers.ProviderListLiveTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
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

  describe "provider form permissions" do
    test "keeps shared visibility unavailable to regular users", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/providers/new")

      refute has_element?(view, "#provider_is_public")
      assert has_element?(view, "#provider-form", "Novos provedores são privados")
    end

    test "allows administrators to publish a provider", %{conn: conn} do
      admin = admin_user_fixture()
      conn = log_in_user(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/providers/new")

      assert has_element?(view, "#provider_is_public")

      assert has_element?(
               view,
               "label[for='provider_is_public']",
               "Compartilhar no catálogo público"
             )
    end
  end

  describe "provider status" do
    setup :register_and_log_in_user

    test "stays mounted while a provider reports sync progress", %{
      conn: conn,
      user: user
    } do
      provider = provider_fixture(user, %{name: "Provider sincronizando"})

      {:ok, view, _html} = live(conn, ~p"/providers")

      Phoenix.PubSub.broadcast(
        Streamix.PubSub,
        "user:#{user.id}:providers",
        {:sync_progress,
         %{
           event: :sync_progress,
           provider_id: provider.id,
           phase: :categories,
           percent: 0,
           type: nil
         }}
      )

      card = "#providers-#{provider.id}"
      assert has_element?(view, card, "Provider sincronizando")
      assert has_element?(view, "#{card} [data-sync-progress]", "Sincronizando categorias")

      assert has_element?(
               view,
               "#{card} [role='progressbar'][aria-valuenow='0'][aria-valuemax='100']"
             )
    end

    test "renders pending sync state and touch-safe labelled actions", %{
      conn: conn,
      user: user
    } do
      provider =
        provider_fixture(user, %{
          name: "Provider pendente",
          sync_status: "pending"
        })

      {:ok, view, _html} = live(conn, ~p"/providers")
      card = "#providers-#{provider.id} [data-sync-status='pending']"

      assert has_element?(view, card, "Pendente")
      assert has_element?(view, "#{card} [data-sync-state-message]")

      assert has_element?(
               view,
               "#{card} button[phx-click='sync_provider'][disabled].min-h-11",
               "Sincronizar"
             )

      assert has_element?(
               view,
               "#{card} a[aria-label='Ver provedor'].min-h-11"
             )

      assert has_element?(
               view,
               "#{card} button[aria-label='Editar provedor'].size-11"
             )

      assert has_element?(
               view,
               "#{card} button[aria-label='Excluir provedor'].size-11"
             )
    end
  end
end
