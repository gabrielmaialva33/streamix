defmodule StreamixWeb.ProvidersLive do
  use StreamixWeb, :live_view

  alias Streamix.Iptv
  alias Streamix.Iptv.Provider

  @impl true
  def mount(_params, _session, socket) do
    user_id = 1
    providers = Iptv.list_providers(user_id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Streamix.PubSub, "user:#{user_id}:providers")
    end

    {:ok,
     socket
     |> assign(:page_title, "Providers")
     |> assign(:user_id, user_id)
     |> assign(:providers, providers)
     |> assign(:provider, nil)
     |> assign(:form, nil)
     |> assign(:testing, false)
     |> assign(:test_result, nil)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Providers")
    |> assign(:provider, nil)
    |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    provider = %Provider{user_id: socket.assigns.user_id}
    changeset = Iptv.change_provider(provider)

    socket
    |> assign(:page_title, "Add Provider")
    |> assign(:provider, provider)
    |> assign(:form, to_form(changeset))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    provider = Iptv.get_user_provider(socket.assigns.user_id, String.to_integer(id))

    if provider do
      changeset = Iptv.change_provider(provider)

      socket
      |> assign(:page_title, "Edit Provider")
      |> assign(:provider, provider)
      |> assign(:form, to_form(changeset))
    else
      socket
      |> put_flash(:error, "Provider not found")
      |> push_navigate(to: ~p"/providers")
    end
  end

  @impl true
  def handle_event("validate", %{"provider" => params}, socket) do
    changeset =
      socket.assigns.provider
      |> Iptv.change_provider(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"provider" => params}, socket) do
    save_provider(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("test_connection", %{"provider" => params}, socket) do
    socket = socket |> assign(:testing, true) |> assign(:test_result, nil)

    case Iptv.test_provider_connection(params["url"], params["username"], params["password"]) do
      {:ok, info} ->
        {:noreply,
         socket
         |> assign(:testing, false)
         |> assign(:test_result, {:ok, info})}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:testing, false)
         |> assign(:test_result, {:error, reason})}
    end
  end

  @impl true
  def handle_event("sync", %{"id" => id}, socket) do
    provider = Iptv.get_provider!(String.to_integer(id))
    Iptv.sync_provider_async(provider)

    {:noreply, put_flash(socket, :info, "Syncing #{provider.name}...")}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    provider = Iptv.get_provider!(String.to_integer(id))

    case Iptv.delete_provider(provider) do
      {:ok, _} ->
        providers = Enum.reject(socket.assigns.providers, &(&1.id == provider.id))

        {:noreply,
         socket
         |> assign(:providers, providers)
         |> put_flash(:info, "Provider deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete provider")}
    end
  end

  @impl true
  def handle_info({:sync_status, %{provider_id: provider_id, status: status} = payload}, socket) do
    providers =
      Enum.map(socket.assigns.providers, fn provider ->
        if provider.id == provider_id do
          channels_count = Map.get(payload, :channels_count, provider.channels_count)
          %{provider | sync_status: status, channels_count: channels_count}
        else
          provider
        end
      end)

    {:noreply, assign(socket, :providers, providers)}
  end

  defp save_provider(socket, :new, params) do
    params = Map.put(params, "user_id", socket.assigns.user_id)

    case Iptv.create_provider(params) do
      {:ok, _provider} ->
        {:noreply,
         socket
         |> put_flash(:info, "Provider created successfully")
         |> push_navigate(to: ~p"/providers")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save_provider(socket, :edit, params) do
    case Iptv.update_provider(socket.assigns.provider, params) do
      {:ok, _provider} ->
        {:noreply,
         socket
         |> put_flash(:info, "Provider updated successfully")
         |> push_navigate(to: ~p"/providers")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={nil}>
      <.header>
        Providers
        <:actions>
          <.link navigate={~p"/providers/new"} class="btn btn-sm btn-primary">
            <.icon name="hero-plus" class="size-4" /> Add Provider
          </.link>
        </:actions>
      </.header>

      <div :if={@providers == []} class="text-center py-12">
        <.icon name="hero-server" class="size-16 text-base-content/30 mx-auto mb-4" />
        <h3 class="text-lg font-medium text-base-content/60">No providers configured</h3>
        <p class="text-base-content/50 mt-1">Add an IPTV provider to start streaming</p>
        <.link navigate={~p"/providers/new"} class="btn btn-primary mt-4">
          Add Your First Provider
        </.link>
      </div>

      <div :if={@providers != []} class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        <.provider_card :for={provider <- @providers} provider={provider} />
      </div>

      <.modal
        :if={@live_action in [:new, :edit]}
        id="provider-modal"
        show
        on_cancel={JS.navigate(~p"/providers")}
      >
        <.header>
          {if @live_action == :new, do: "Add Provider", else: "Edit Provider"}
        </.header>

        <.form
          for={@form}
          id="provider-form"
          phx-change="validate"
          phx-submit="save"
          class="mt-4 space-y-4"
        >
          <.input field={@form[:name]} type="text" label="Name" placeholder="My IPTV Provider" />
          <.input field={@form[:url]} type="url" label="Server URL" placeholder="http://example.com" />
          <.input field={@form[:username]} type="text" label="Username" />
          <.input field={@form[:password]} type="password" label="Password" />

          <div :if={@test_result} class="alert">
            <div :if={match?({:ok, _}, @test_result)} class="alert-success">
              <.icon name="hero-check-circle" class="size-5" />
              <span>Connection successful!</span>
            </div>
            <div :if={match?({:error, _}, @test_result)} class="alert-error">
              <.icon name="hero-x-circle" class="size-5" />
              <span>{Iptv.connection_error_message(elem(@test_result, 1))}</span>
            </div>
          </div>

          <div class="flex justify-between pt-4">
            <button
              type="button"
              phx-click="test_connection"
              phx-value-provider={Jason.encode!(@form.params)}
              class="btn btn-ghost"
              disabled={@testing}
            >
              <.icon
                name="hero-signal"
                class={["size-4", @testing && "animate-pulse"]}
              />
              {if @testing, do: "Testing...", else: "Test Connection"}
            </button>

            <div class="flex gap-2">
              <.link navigate={~p"/providers"} class="btn btn-ghost">
                Cancel
              </.link>
              <button type="submit" class="btn btn-primary">
                {if @live_action == :new, do: "Create", else: "Save"}
              </button>
            </div>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end
end
