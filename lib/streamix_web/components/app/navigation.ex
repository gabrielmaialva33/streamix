defmodule StreamixWeb.App.Navigation do
  @moduledoc """
  Navigation components shared across the web app shell.
  """

  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import StreamixWeb.CoreComponents

  attr :class, :string, default: nil

  def theme_toggle(assigns) do
    ~H"""
    <button
      id={"theme-toggle-#{System.unique_integer()}"}
      type="button"
      phx-hook="ThemeToggle"
      class={[
        "flex items-center gap-2 p-2 rounded-lg text-text-secondary hover:text-text-primary hover:bg-surface-hover transition-colors",
        @class
      ]}
      title="Alternar tema"
    >
      <.icon name="hero-sun" class="hidden dark:block size-5" />
      <.icon name="hero-moon" class="block dark:hidden size-5" />
      <span class="sr-only">Alternar tema</span>
    </button>
    """
  end

  attr :current_scope, :any, default: nil
  attr :current_path, :string, default: "/"

  def sidebar(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div class="p-4 border-b border-border">
        <.link navigate={~p"/"} class="flex items-center gap-2 text-xl font-bold text-brand">
          <.icon name="hero-play-circle-solid" class="size-8" />
          <span>Streamix</span>
        </.link>
      </div>

      <nav class="flex-1 p-4 space-y-6">
        <div :if={@current_scope} class="space-y-1">
          <p class="text-xs font-semibold text-text-muted uppercase tracking-wider px-3 mb-2">
            Menu
          </p>
          <.nav_item
            path={~p"/providers"}
            icon="hero-server-stack"
            label="Provedores"
            current_path={@current_path}
          />
          <.nav_item
            path={~p"/search"}
            icon="hero-magnifying-glass"
            label="Buscar"
            current_path={@current_path}
          />
          <.nav_item
            path={~p"/plans"}
            icon="hero-sparkles"
            label="Planos"
            current_path={@current_path}
          />
        </div>

        <div :if={@current_scope} class="space-y-1">
          <p class="text-xs font-semibold text-text-muted uppercase tracking-wider px-3 mb-2">
            Biblioteca
          </p>
          <.nav_item
            path={~p"/favorites"}
            icon="hero-heart"
            label="Favoritos"
            current_path={@current_path}
          />
          <.nav_item
            path={~p"/history"}
            icon="hero-clock"
            label="Histórico"
            current_path={@current_path}
          />
        </div>
      </nav>

      <div class="p-4 border-t border-border">
        <div :if={@current_scope} class="space-y-1">
          <.nav_item
            :if={Streamix.Accounts.admin?(@current_scope.user)}
            path={~p"/admin"}
            icon="hero-shield-check"
            label="Gerenciamento"
            current_path={@current_path}
          />
          <.nav_item
            path={~p"/settings"}
            icon="hero-cog-6-tooth"
            label="Configurações"
            current_path={@current_path}
          />
          <.link
            href={~p"/logout"}
            method="delete"
            class="flex items-center gap-3 px-3 py-2 rounded-lg text-text-secondary hover:bg-surface-hover hover:text-text-primary transition-colors w-full"
          >
            <.icon name="hero-arrow-right-on-rectangle" class="size-5" />
            <span>Sair</span>
          </.link>
        </div>

        <div :if={!@current_scope} class="space-y-2">
          <.link
            navigate={~p"/plans"}
            class="flex items-center justify-center gap-2 px-3 py-2 rounded-lg border border-brand/30 bg-brand/10 text-brand hover:bg-brand/20 transition-colors w-full"
          >
            <.icon name="hero-sparkles" class="size-5" />
            <span>Ver planos premium</span>
          </.link>
          <.link
            navigate={~p"/login"}
            class="flex items-center justify-center gap-2 px-3 py-2 rounded-lg bg-brand text-white hover:bg-brand-hover transition-colors w-full"
          >
            <.icon name="hero-arrow-right-end-on-rectangle" class="size-5" />
            <span>Entrar</span>
          </.link>
          <.link
            navigate={~p"/register"}
            class="flex items-center justify-center gap-2 px-3 py-2 rounded-lg border border-border text-text-secondary hover:bg-surface-hover hover:text-text-primary transition-colors w-full"
          >
            <.icon name="hero-user-plus" class="size-5" />
            <span>Cadastrar</span>
          </.link>
        </div>
      </div>
    </div>
    """
  end

  defp nav_item(assigns) do
    active = assigns.current_path == assigns.path
    assigns = assign(assigns, :active, active)

    ~H"""
    <.link
      navigate={@path}
      class={[
        "flex items-center gap-3 px-3 py-2 rounded-lg transition-colors",
        @active && "bg-brand/20 text-brand font-medium",
        !@active && "text-text-secondary hover:bg-surface-hover hover:text-text-primary"
      ]}
    >
      <.icon name={@icon} class="size-5" />
      <span>{@label}</span>
    </.link>
    """
  end

  attr :path, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :icon_active, :string, required: true
  attr :active, :boolean, default: false
  attr :accent, :string, default: nil

  def nav_link(assigns) do
    ~H"""
    <.link
      navigate={@path}
      aria-current={@active && "page"}
      class={[
        "flex items-center gap-1.5 px-3 py-2 rounded-xl text-sm font-medium transition-all",
        @active && !@accent && "text-text-primary bg-surface-hover/60",
        !@active && !@accent &&
          "text-text-secondary hover:text-text-primary hover:bg-surface-hover/40",
        @active && @accent == "accent" && "text-accent bg-accent/10",
        !@active && @accent == "accent" &&
          "text-text-secondary hover:text-accent hover:bg-accent/10"
      ]}
    >
      <.icon name={if @active, do: @icon_active, else: @icon} class="size-4" />
      <span>{@label}</span>
    </.link>
    """
  end

  attr :path, :string, required: true
  attr :icon, :string, required: true
  attr :icon_active, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :center, :boolean, default: false

  def bottom_tab(assigns) do
    ~H"""
    <.link
      navigate={@path}
      aria-current={@active && "page"}
      class={[
        "flex flex-col items-center justify-center flex-1 h-full py-1.5 transition-all touch-manipulation",
        @active && "text-brand",
        !@active && "text-text-secondary active:text-text-primary"
      ]}
    >
      <span class={[
        "flex items-center justify-center rounded-xl transition-all",
        @active && "bg-brand/15 px-4 py-1",
        !@active && "px-2 py-1"
      ]}>
        <.icon
          name={if @active, do: @icon_active, else: @icon}
          class={["transition-all", @center && "size-6", !@center && "size-5"]}
        />
      </span>
      <span class="text-[10px] mt-0.5 font-medium">{@label}</span>
    </.link>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :rest, :global

  def dropdown_item(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="flex items-center gap-2.5 px-4 py-2 text-sm text-text-secondary hover:text-text-primary hover:bg-surface-hover/50 transition-colors"
      {@rest}
    >
      <.icon name={@icon} class="size-4" />
      <span>{@label}</span>
    </.link>
    """
  end
end
