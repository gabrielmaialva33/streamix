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
    <div class="px-[4%] py-8">
      <div class="max-w-2xl mx-auto space-y-8">
        <div>
          <h1 class="text-3xl font-bold text-text-primary">Configurações</h1>
          <p class="text-text-secondary mt-1">Gerencie as configurações da sua conta</p>
        </div>

        <div class="bg-surface rounded-xl p-6 border border-border">
          <h3 class="text-lg font-semibold text-text-primary mb-4">Alterar Email</h3>

          <.simple_form
            for={@email_form}
            id="email_form"
            phx-change="validate_email"
            phx-submit="update_email"
          >
            <.input field={@email_form[:email]} type="email" label="Email" required autocomplete="email" />
            <.input
              field={@email_form[:current_password]}
              type="password"
              label="Senha Atual"
              required
              name="current_password"
              id="email_current_password"
              autocomplete="current-password"
            />

            <:actions>
              <.button type="submit" variant="primary">
                Alterar Email
              </.button>
            </:actions>
          </.simple_form>
        </div>

        <div class="bg-surface rounded-xl p-6 border border-border">
          <h3 class="text-lg font-semibold text-text-primary mb-4">Alterar Senha</h3>

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

            <.input field={@password_form[:password]} type="password" label="Nova Senha" required autocomplete="new-password" />
            <p class="text-xs text-text-secondary -mt-2">Mínimo de 12 caracteres</p>
            <.input
              field={@password_form[:password_confirmation]}
              type="password"
              label="Confirmar Nova Senha"
              required
              autocomplete="new-password"
            />
            <.input
              field={@password_form[:current_password]}
              type="password"
              label="Senha Atual"
              required
              name="current_password"
              id="password_current_password"
              autocomplete="current-password"
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
