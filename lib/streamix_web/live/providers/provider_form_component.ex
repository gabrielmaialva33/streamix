defmodule StreamixWeb.Providers.ProviderFormComponent do
  @moduledoc """
  LiveComponent for creating and editing IPTV providers.
  """
  use StreamixWeb, :live_component

  alias Streamix.Iptv
  alias Streamix.Iptv.Provider

  def mount(socket) do
    {:ok,
     socket
     |> assign(testing: false)
     |> assign(test_result: nil)}
  end

  def update(%{provider: provider} = assigns, socket) do
    changeset =
      if provider do
        Iptv.change_provider(provider)
      else
        Iptv.change_provider(%Provider{})
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(form: to_form(changeset, as: "provider"))}
  end

  def handle_event("validate", %{"provider" => params}, socket) do
    changeset =
      (socket.assigns.provider || %Provider{})
      |> Iptv.change_provider(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: "provider"))}
  end

  def handle_event("test_connection", _, socket) do
    params = socket.assigns.form.params

    socket = assign(socket, testing: true, test_result: nil)

    case Iptv.test_connection(params["url"], params["username"], params["password"]) do
      {:ok, account_info} ->
        {:noreply,
         assign(socket,
           testing: false,
           test_result: {:ok, account_info}
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           testing: false,
           test_result: {:error, format_error(reason)}
         )}
    end
  end

  def handle_event("save", %{"provider" => params}, socket) do
    user_id = socket.assigns.current_scope.user.id
    params = Map.put(params, "user_id", user_id)

    case socket.assigns.provider do
      nil -> create_provider(socket, params)
      provider -> update_provider(socket, provider, params)
    end
  end

  defp create_provider(socket, params) do
    with {:ok, _account_info} <-
           Iptv.test_connection(params["url"], params["username"], params["password"]),
         {:ok, provider} <- Iptv.create_provider(params) do
      notify_parent({:saved, provider})
      {:noreply, socket}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "provider"))}

      {:error, reason} ->
        {:noreply, assign(socket, test_result: {:error, format_error(reason)})}
    end
  end

  defp update_provider(socket, provider, params) do
    case Iptv.update_provider(provider, params) do
      {:ok, provider} ->
        notify_parent({:saved, provider})
        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "provider"))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  defp format_error(:invalid_url), do: "Formato de URL inválido"
  defp format_error(:connection_refused), do: "Não foi possível conectar ao servidor"
  defp format_error(:timeout), do: "Tempo limite de conexão esgotado"
  defp format_error(:invalid_credentials), do: "Usuário ou senha inválidos"
  defp format_error(:not_found), do: "Servidor não encontrado"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(_), do: "Ocorreu um erro desconhecido"

  def render(assigns) do
    ~H"""
    <div>
      <h3 class="text-lg font-bold mb-4">
        {if @provider, do: "Editar Provedor", else: "Adicionar Provedor"}
      </h3>

      <.simple_form
        for={@form}
        id="provider-form"
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
      >
        <.input field={@form[:name]} label="Nome" placeholder="Meu Serviço IPTV" required />
        <.input
          field={@form[:url]}
          label="URL do Servidor"
          placeholder="http://exemplo.com:8080"
          required
        />
        <.input field={@form[:username]} label="Usuário" required />
        <.input field={@form[:password]} type="password" label="Senha" required />

        <div
          :if={@test_result}
          class={[
            "alert mb-4",
            elem(@test_result, 0) == :ok && "alert-success",
            elem(@test_result, 0) == :error && "alert-error"
          ]}
        >
          <%= case @test_result do %>
            <% {:ok, info} -> %>
              <.icon name="hero-check-circle" class="size-5" />
              <span>Conexão bem sucedida!</span>
              <span :if={info["user_info"]["username"]}>
                Conta: {info["user_info"]["username"]}
              </span>
            <% {:error, msg} -> %>
              <.icon name="hero-x-circle" class="size-5" />
              <span>{msg}</span>
          <% end %>
        </div>

        <:actions>
          <button
            type="button"
            phx-click="test_connection"
            phx-target={@myself}
            disabled={@testing}
            class="btn btn-ghost"
          >
            <.icon
              :if={@testing}
              name="hero-arrow-path"
              class="size-4 animate-spin"
            />
            <.icon :if={!@testing} name="hero-signal" class="size-4" /> Testar Conexão
          </button>
          <.button type="submit" variant="primary">
            {if @provider, do: "Atualizar", else: "Adicionar Provedor"}
          </.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end
end
