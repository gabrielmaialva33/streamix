defmodule StreamixWeb.User.LoginLive do
  use StreamixWeb, :live_view

  def mount(_params, _session, socket) do
    email = Phoenix.Flash.get(socket.assigns.flash, :email)
    form = to_form(%{"email" => email, "remember_me" => "true"}, as: "user")

    socket =
      socket
      |> assign(page_title: "Entrar")
      |> assign(current_path: "/login")
      |> assign(form: form)

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <%!-- Logo (mobile only — desktop has branded panel) --%>
    <div class="flex items-center justify-center gap-2 mb-8 lg:hidden text-brand">
      <.icon name="hero-play-circle-solid" class="size-8" />
      <span class="text-2xl font-bold tracking-tight">Streamix</span>
    </div>

    <div class="text-center mb-8">
      <h1 class="text-2xl font-semibold text-text-primary tracking-tight">Entrar</h1>
      <p class="text-sm text-text-secondary mt-2">
        Não tem uma conta?
        <.link navigate={~p"/register"} class="text-brand hover:underline font-medium">
          Cadastre-se
        </.link>
      </p>
    </div>

    <.simple_form for={@form} action={~p"/login"} method="post">
      <.input field={@form[:email]} type="email" label="Email" required autocomplete="username" />
      <.input
        field={@form[:password]}
        type="password"
        label="Senha"
        required
        autocomplete="current-password"
      />

      <div class="w-full">
        <.input
          field={@form[:remember_me]}
          type="checkbox"
          label="Lembrar de mim"
          class="size-5 shrink-0 rounded border-border bg-surface text-brand focus:ring-2 focus:ring-brand focus:ring-offset-background disabled:opacity-50"
          aria-describedby="remember-me-help"
        />
        <p id="remember-me-help" class="-mt-2 pl-8 text-xs text-text-muted">
          Mantém sua conta conectada neste dispositivo por até 60 dias.
        </p>
      </div>

      <:actions>
        <.button type="submit" variant="primary" class="w-full py-3 text-base font-semibold">
          Entrar
        </.button>
      </:actions>
    </.simple_form>
    """
  end
end
