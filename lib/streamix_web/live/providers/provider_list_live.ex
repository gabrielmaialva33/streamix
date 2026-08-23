defmodule StreamixWeb.Providers.ProviderListLive do
  use StreamixWeb, :live_view

  import StreamixWeb.App.Feedback
  import StreamixWeb.App.Media

  alias Streamix.{Accounts, Iptv}

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    user_id = user.id

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Streamix.PubSub, "user:#{user_id}:providers")
    end

    # Admins see every provider (including the global system rows
    # owned by the platform); regular users only see what they own.
    providers =
      case Accounts.role_name(user) do
        "admin" -> Iptv.list_providers(user_id, scope: :all)
        _ -> Iptv.list_providers(user_id)
      end

    socket =
      socket
      |> assign(page_title: "Provedores")
      |> assign(current_path: "/providers")
      |> assign(empty_providers: Enum.empty?(providers))
      |> assign(sync_progress: %{})
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

  defp apply_action(socket, :edit, %{"provider_id" => id}) do
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
      case Iptv.async_sync_provider(provider) do
        {:ok, _job} ->
          {:noreply,
           socket
           |> stream_insert(:providers, %{provider | sync_status: "pending"})
           |> put_sync_progress(provider.id, %{phase: :queued, percent: 0, type: nil})
           |> put_flash(:info, "Sincronização iniciada para #{provider.name}")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Não foi possível agendar a sincronização")}
      end
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Esse provedor não está disponível para sua conta. Pode estar inativo, ter sido removido ou ser privado de outro usuário."
       )}
    end
  end

  def handle_event("edit_provider", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/providers/#{id}/edit")}
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
      {:noreply,
       put_flash(
         socket,
         :error,
         "Esse provedor não está disponível para sua conta. Pode estar inativo, ter sido removido ou ser privado de outro usuário."
       )}
    end
  end

  def handle_event("close_modal", _, socket) do
    {:noreply, push_patch(socket, to: ~p"/providers")}
  end

  def handle_info({:sync_progress, %{provider_id: id} = payload}, socket) do
    user_id = socket.assigns.current_scope.user.id

    case Iptv.get_user_provider(user_id, id) do
      nil ->
        {:noreply, socket}

      provider ->
        {:noreply,
         socket
         |> put_sync_progress(id, normalize_sync_progress(payload))
         |> stream_insert(:providers, provider)}
    end
  end

  def handle_info({:sync_progress, _payload}, socket), do: {:noreply, socket}

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

        socket = stream_insert(socket, :providers, updated_provider)

        socket =
          if status in ["completed", "failed", "partial"] do
            clear_sync_progress(socket, id)
          else
            socket
          end

        {:noreply, socket}
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

      <div
        id="providers"
        phx-update="stream"
        aria-label="Provedores configurados"
        class="grid gap-4 sm:gap-6 md:grid-cols-2 lg:grid-cols-3"
      >
        <div :for={{dom_id, provider} <- @streams.providers} id={dom_id} class="h-full min-w-0">
          <.provider_card
            provider={provider}
            sync_progress={Map.get(@sync_progress, provider.id)}
          />
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

  defp put_sync_progress(socket, provider_id, progress) do
    assign(socket, :sync_progress, Map.put(socket.assigns.sync_progress, provider_id, progress))
  end

  defp clear_sync_progress(socket, provider_id) do
    assign(socket, :sync_progress, Map.delete(socket.assigns.sync_progress, provider_id))
  end

  defp normalize_sync_progress(payload) do
    percent =
      payload
      |> Map.get(:percent, 0)
      |> normalize_percent()

    %{
      phase: Map.get(payload, :phase, :syncing),
      percent: percent,
      type: Map.get(payload, :type)
    }
  end

  defp normalize_percent(value) when is_integer(value), do: max(0, min(100, value))
  defp normalize_percent(value) when is_float(value), do: value |> round() |> normalize_percent()
  defp normalize_percent(_value), do: 0
end
