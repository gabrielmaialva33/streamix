defmodule StreamixWeb.User.SettingsLive do
  use StreamixWeb, :live_view

  alias Streamix.Accounts

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    socket =
      socket
      |> assign(page_title: "Configurações")
      |> assign(current_path: "/settings")
      |> assign(current_email: user.email)
      |> assign(email_form: to_form(Accounts.change_user_email(user), as: "user"))
      |> assign(password_form: to_form(Accounts.change_user_password(user), as: "user"))
      |> assign(trigger_submit: false)

    {:ok, socket}
  end

  def handle_event("validate_email", %{"user" => params}, socket) do
    user = socket.assigns.current_scope.user

    changeset =
      user
      |> Accounts.change_user_email(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, email_form: to_form(changeset, as: "user"))}
  end

  def handle_event("update_email", %{"user" => _params}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "A funcionalidade de alteração de email ainda não está implementada")}
  end

  def handle_event("validate_password", %{"user" => params}, socket) do
    user = socket.assigns.current_scope.user

    changeset =
      user
      |> Accounts.change_user_password(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, password_form: to_form(changeset, as: "user"))}
  end

  def handle_event("update_password", %{"user" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.update_user_password(user, params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Senha atualizada com sucesso")
         |> assign(trigger_submit: true)}

      {:error, changeset} ->
        {:noreply, assign(socket, password_form: to_form(changeset, as: "user"))}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-2xl space-y-8">
      <.header>
        Configurações
        <:subtitle>Gerencie as configurações da sua conta</:subtitle>
      </.header>

      <div class="card bg-base-200">
        <div class="card-body">
          <h3 class="card-title text-lg">Alterar Email</h3>

          <.simple_form
            for={@email_form}
            id="email_form"
            phx-change="validate_email"
            phx-submit="update_email"
          >
            <.input field={@email_form[:email]} type="email" label="Email" required />
            <.input
              field={@email_form[:current_password]}
              type="password"
              label="Senha Atual"
              required
              name="current_password"
              id="email_current_password"
            />

            <:actions>
              <.button type="submit" variant="primary">
                Alterar Email
              </.button>
            </:actions>
          </.simple_form>
        </div>
      </div>

      <div class="card bg-base-200">
        <div class="card-body">
          <h3 class="card-title text-lg">Alterar Senha</h3>

          <.simple_form
            for={@password_form}
            id="password_form"
            phx-change="validate_password"
            phx-submit="update_password"
            phx-trigger-action={@trigger_submit}
            action={~p"/login"}
            method="post"
          >
            <.input type="hidden" name={@password_form[:email].name} value={@current_email} />

            <.input field={@password_form[:password]} type="password" label="Nova Senha" required />
            <.input
              field={@password_form[:password_confirmation]}
              type="password"
              label="Confirmar Nova Senha"
              required
            />
            <.input
              field={@password_form[:current_password]}
              type="password"
              label="Senha Atual"
              required
              name="current_password"
              id="password_current_password"
            />

            <:actions>
              <.button type="submit" variant="primary">
                Alterar Senha
              </.button>
            </:actions>
          </.simple_form>
        </div>
      </div>
    </div>
    """
  end
end
