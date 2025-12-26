defmodule StreamixWeb.User.RegisterLive do
  use StreamixWeb, :live_view

  alias Streamix.Accounts
  alias Streamix.Accounts.User

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_registration(%User{})

    socket =
      socket
      |> assign(page_title: "Cadastro")
      |> assign(current_path: "/register")
      |> assign(trigger_submit: false)
      |> assign_form(changeset)

    {:ok, socket, temporary_assigns: [form: nil]}
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      %User{}
      |> Accounts.change_user_registration(user_params)
      |> Map.put(:action, :validate)

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
    <div class="min-h-[calc(100vh-80px)] flex items-center justify-center px-4">
      <div class="w-full max-w-md bg-zinc-900/80 backdrop-blur-sm rounded-lg p-8 shadow-2xl border border-white/10">
        <h1 class="text-3xl font-bold text-white mb-2">Criar conta</h1>
        <p class="text-zinc-400 mb-6">
          Já tem uma conta?
          <.link navigate={~p"/login"} class="text-primary hover:underline font-medium">
            Entrar
          </.link>
        </p>

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
          <p class="text-xs text-zinc-500 -mt-2">Mínimo de 12 caracteres</p>
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

        <p class="text-xs text-zinc-500 text-center mt-6">
          Ao criar uma conta, você concorda com nossos
          <span class="text-zinc-400">Termos de Uso</span>
          e <span class="text-zinc-400">Política de Privacidade</span>.
        </p>
      </div>
    </div>
    """
  end
end
