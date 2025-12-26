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
    <div class="max-w-md mx-auto mt-10">
      <.header>
        Criar uma conta
        <:subtitle>
          Já tem uma conta?
          <.link navigate={~p"/login"} class="font-semibold text-primary hover:underline">
            Entrar
          </.link>
        </:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="registration_form"
        phx-submit="save"
        phx-change="validate"
        phx-trigger-action={@trigger_submit}
        action={~p"/login"}
        method="post"
        class="mt-6"
      >
        <.input field={@form[:email]} type="email" label="Email" required autocomplete="email" />
        <.input
          field={@form[:password]}
          type="password"
          label="Senha"
          required
          autocomplete="new-password"
        />

        <:actions>
          <.button type="submit" variant="primary" class="w-full">
            Criar conta
          </.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end
end
