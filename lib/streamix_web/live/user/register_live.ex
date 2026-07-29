defmodule StreamixWeb.User.RegisterLive do
  use StreamixWeb, :live_view

  alias Streamix.Accounts

  def mount(_params, _session, socket) do
    changeset = Accounts.new_user_registration()

    socket =
      socket
      |> assign(page_title: "Cadastro")
      |> assign(current_path: "/register")
      |> assign(trigger_submit: false)
      |> assign_form(changeset)

    {:ok, socket, temporary_assigns: [form: nil]}
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.new_user_registration(user_params) |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user_with_password(user_params) do
      {:ok, user} ->
        changeset = Accounts.change_user_registration(user)
        {:noreply, socket |> assign(trigger_submit: true) |> assign_form(changeset)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form, check_errors: changeset.action != nil)
  end

  def render(assigns) do
    ~H"""
    <%!-- Logo (mobile only — desktop has branded panel) --%>
    <div class="flex items-center justify-center gap-2 mb-8 lg:hidden text-brand">
      <.icon name="hero-play-circle-solid" class="size-8" />
      <span class="text-2xl font-bold tracking-tight">Streamix</span>
    </div>

    <div class="text-center mb-8">
      <h1 class="text-2xl font-semibold text-text-primary tracking-tight">Criar conta</h1>
      <p class="text-sm text-text-secondary mt-2">
        Já tem uma conta?
        <.link navigate={~p"/login"} class="text-brand hover:underline font-medium">
          Entrar
        </.link>
      </p>
    </div>

    <.simple_form
      for={@form}
      id="registration_form"
      phx-submit="save"
      phx-change="validate"
      phx-trigger-action={@trigger_submit}
      action={~p"/login"}
      method="post"
    >
      <.input field={@form[:email]} type="email" label="Email" required autocomplete="email" />
      <.input
        field={@form[:password]}
        type="password"
        label="Senha"
        required
        autocomplete="new-password"
      />
      <p class="text-xs text-text-muted -mt-2">Mínimo de 12 caracteres</p>
      <.input
        field={@form[:password_confirmation]}
        type="password"
        label="Confirmar senha"
        required
        autocomplete="new-password"
      />

      <:actions>
        <.button type="submit" variant="primary" class="w-full py-3 text-base font-semibold">
          Criar conta
        </.button>
      </:actions>
    </.simple_form>

    <p class="text-xs text-text-muted text-center mt-6">
      Ao criar uma conta, você concorda com nossos
      <span class="text-text-secondary">Termos de Uso</span>
      e <span class="text-text-secondary">Política de Privacidade</span>.
    </p>
    """
  end
end
