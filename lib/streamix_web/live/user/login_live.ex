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
    <div class="min-h-[calc(100vh-80px)] flex items-center justify-center -mx-[4%] px-4 sm:mx-0">
      <div class="w-full max-w-md bg-surface/90 backdrop-blur-sm rounded-none sm:rounded-lg p-6 sm:p-8 shadow-2xl border-y sm:border border-white/10">
        <h1 class="text-2xl sm:text-3xl font-bold text-white mb-1 sm:mb-2">Entrar</h1>
        <p class="text-text-secondary text-sm sm:text-base mb-6 sm:mb-8">
          Não tem uma conta?
          <.link navigate={~p"/register"} class="text-brand hover:underline font-medium">
            Cadastre-se
          </.link>
        </p>

        <.simple_form for={@form} action={~p"/login"} phx-change="validate" method="post">
          <.input field={@form[:email]} type="email" label="Email" required autocomplete="email" />
          <.input
            field={@form[:password]}
            type="password"
            label="Senha"
            required
            autocomplete="current-password"
          />

          <div class="flex items-center justify-between">
            <.input field={@form[:remember_me]} type="checkbox" label="Lembrar de mim" />
          </div>

          <:actions>
            <.button type="submit" variant="primary" class="w-full py-3 text-base font-semibold">
              Entrar
            </.button>
          </:actions>
        </.simple_form>
      </div>
    </div>
    """
  end
end
