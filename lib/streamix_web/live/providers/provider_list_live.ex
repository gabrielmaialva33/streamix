defmodule StreamixWeb.Providers.ProviderListLive do
  use StreamixWeb, :live_view

  import StreamixWeb.AppComponents

  alias Streamix.Iptv

  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Streamix.PubSub, "user:#{user_id}:providers")
    end

    providers = Iptv.list_providers(user_id)

    socket =
      socket
      |> assign(page_title: "Provedores")
      |> assign(current_path: "/providers")
      |> assign(empty_providers: Enum.empty?(providers))
      |> stream(:providers, providers)

    {:ok, socket}
  end

  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(page_title: "Adicionar Provedor")
    |> assign(provider: nil)
    |> assign(show_modal: true)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    user_id = socket.assigns.current_scope.user.id
    provider = Iptv.get_user_provider(user_id, id)

    socket
    |> assign(page_title: "Editar Provedor")
    |> assign(provider: provider)
    |> assign(show_modal: true)
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(page_title: "Provedores")
    |> assign(provider: nil)
    |> assign(show_modal: false)
  end

  def handle_event("sync_provider", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    provider = Iptv.get_user_provider(user_id, id)

    if provider do
      Iptv.async_sync_provider(provider)

      {:noreply,
       socket
       |> stream_insert(:providers, %{provider | sync_status: "pending"})
       |> put_flash(:info, "Sincronização iniciada para #{provider.name}")}
    else
      {:noreply, put_flash(socket, :error, "Provedor não encontrado")}
    end
  end

  def handle_event("delete_provider", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    provider = Iptv.get_user_provider(user_id, id)

    if provider do
      case Iptv.delete_provider(provider) do
        {:ok, _} ->
          {:noreply,
           socket
           |> stream_delete(:providers, provider)
           |> put_flash(:info, "Provedor excluído")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Não foi possível excluir o provedor")}
      end
    else
      {:noreply, put_flash(socket, :error, "Provedor não encontrado")}
    end
  end

  def handle_event("close_modal", _, socket) do
    {:noreply, push_patch(socket, to: ~p"/providers")}
  end

  def handle_info({:sync_status, %{provider_id: id, status: status} = payload}, socket) do
    user_id = socket.assigns.current_scope.user.id

    case Iptv.get_user_provider(user_id, id) do
      nil ->
        {:noreply, socket}

      provider ->
        updated_provider = %{
          provider
          | sync_status: status,
            live_channels_count:
              Map.get(payload, :live_channels_count, provider.live_channels_count),
            movies_count: Map.get(payload, :movies_count, provider.movies_count),
            series_count: Map.get(payload, :series_count, provider.series_count),
            live_synced_at:
              if(status == "completed", do: DateTime.utc_now(), else: provider.live_synced_at)
        }

        {:noreply, stream_insert(socket, :providers, updated_provider)}
    end
  end

  def handle_info({StreamixWeb.Providers.ProviderFormComponent, {:saved, provider}}, socket) do
    {:noreply,
     socket
     |> stream_insert(:providers, provider)
     |> assign(empty_providers: false)
     |> put_flash(:info, "Provedor salvo com sucesso")
     |> push_patch(to: ~p"/providers")}
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-4 sm:space-y-6">
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 sm:gap-4">
        <div>
          <h1 class="text-2xl sm:text-3xl font-bold text-text-primary">Meus Provedores</h1>
          <p class="text-sm sm:text-base text-text-secondary mt-1">Gerencie seus provedores IPTV</p>
        </div>
        <.button
          :if={!@empty_providers}
          navigate={~p"/providers/new"}
          variant="primary"
          class="w-full sm:w-auto"
        >
          <.icon name="hero-plus" class="size-4 sm:size-5" /> Adicionar Provedor
        </.button>
      </div>

      <div id="providers" phx-update="stream" class="grid gap-4 sm:gap-6 md:grid-cols-2 lg:grid-cols-3">
        <div :for={{dom_id, provider} <- @streams.providers} id={dom_id}>
          <.provider_card provider={provider} />
        </div>
      </div>

      <div :if={@empty_providers} class="py-8 sm:py-12">
        <.empty_state
          icon="hero-server-stack"
          title="Nenhum provedor ainda"
          message="Adicione seu primeiro provedor IPTV para começar a assistir"
        >
          <:action>
            <.button navigate={~p"/providers/new"} variant="primary">
              <.icon name="hero-plus" class="size-4 sm:size-5" /> Adicionar Provedor
            </.button>
          </:action>
        </.empty_state>
      </div>

      <.modal :if={@show_modal} id="provider-modal" show on_cancel={JS.patch(~p"/providers")}>
        <.live_component
          module={StreamixWeb.Providers.ProviderFormComponent}
          id={(@provider && @provider.id) || :new}
          provider={@provider}
          current_scope={@current_scope}
        />
      </.modal>
    </div>
    """
  end
end
