defmodule StreamixWeb.User.LoginLive do
  use StreamixWeb, :live_view

  def mount(_params, _session, socket) do
    email = Phoenix.Flash.get(socket.assigns.flash, :email)
    form = to_form(%{"email" => email}, as: "user")

    socket =
      socket
      |> assign(page_title: "Entrar")
      |> assign(current_path: "/login")
      |> assign(form: form)

    {:ok, socket, temporary_assigns: [form: form]}
  end

  def handle_event("validate", %{"user" => params}, socket) do
    form = to_form(params, as: "user")
    {:noreply, assign(socket, form: form)}
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-md mx-auto mt-10">
      <.header>
        Entrar no Streamix
        <:subtitle>
          Não tem uma conta?
          <.link navigate={~p"/register"} class="font-semibold text-primary hover:underline">
            Cadastre-se
          </.link>
        </:subtitle>
      </.header>

      <.simple_form for={@form} action={~p"/login"} phx-change="validate" method="post" class="mt-6">
        <.input field={@form[:email]} type="email" label="Email" required autocomplete="email" />
        <.input
          field={@form[:password]}
          type="password"
          label="Senha"
          required
          autocomplete="current-password"
        />

        <div class="flex items-center gap-2">
          <.input field={@form[:remember_me]} type="checkbox" label="Lembrar de mim" />
        </div>

        <:actions>
          <.button type="submit" variant="primary" class="w-full">
            Entrar
          </.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end
end
