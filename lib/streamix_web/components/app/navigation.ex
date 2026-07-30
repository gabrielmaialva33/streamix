defmodule StreamixWeb.App.Navigation do
  @moduledoc """
  Navigation components shared across the web app shell.
  """

  use Phoenix.Component

  import StreamixWeb.CoreComponents

  alias StreamixWeb.LiveSessionNavigation

  attr :path, :string, required: true
  attr :current_path, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :icon_active, :string, required: true
  attr :active, :boolean, default: false
  attr :accent, :string, default: nil

  def nav_link(assigns) do
    ~H"""
    <.session_link
      path={@path}
      current_path={@current_path}
      aria-current={@active && "page"}
      class={[
        "flex min-h-11 items-center gap-1.5 rounded-xl px-3 py-2 text-sm font-medium transition-all",
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
    </.session_link>
    """
  end

  attr :path, :string, required: true
  attr :current_path, :string, required: true
  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :icon_active, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  def bottom_tab(assigns) do
    ~H"""
    <.session_link
      id={@id}
      path={@path}
      current_path={@current_path}
      aria-label={@label}
      aria-current={@active && "page"}
      class={[
        "mobile-bottom-tab flex min-h-11 min-w-0 flex-col items-center justify-center py-1.5 transition-colors touch-manipulation",
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
          class="size-5 transition-transform"
        />
      </span>
      <span class="text-[10px] mt-0.5 font-medium">{@label}</span>
    </.session_link>
    """
  end

  attr :home_path, :string, required: true
  attr :current_path, :string, required: true

  def mobile_bottom_nav(assigns) do
    ~H"""
    <nav
      id="mobile-bottom-nav"
      aria-label="Navegação principal"
      class="mobile-bottom-nav fixed inset-x-0 bottom-0 z-40 md:hidden"
    >
      <div class="grid h-16 grid-cols-5 items-stretch">
        <.bottom_tab
          id="mobile-tab-home"
          path={@home_path}
          current_path={@current_path}
          icon="hero-home"
          icon_active="hero-home-solid"
          label="Início"
          active={@current_path in ["/", "/home"]}
        />
        <.bottom_tab
          id="mobile-tab-catalog"
          path="/browse"
          current_path={@current_path}
          icon="hero-squares-2x2"
          icon_active="hero-squares-2x2-solid"
          label="Catálogo"
          active={String.starts_with?(@current_path, "/browse")}
        />
        <.bottom_tab
          id="mobile-tab-search"
          path="/search"
          current_path={@current_path}
          icon="hero-magnifying-glass"
          icon_active="hero-magnifying-glass-solid"
          label="Busca"
          active={String.starts_with?(@current_path, "/search")}
        />
        <.bottom_tab
          id="mobile-tab-favorites"
          path="/favorites"
          current_path={@current_path}
          icon="hero-heart"
          icon_active="hero-heart-solid"
          label="Lista"
          active={String.starts_with?(@current_path, "/favorites")}
        />
        <.bottom_tab
          id="mobile-tab-profile"
          path="/settings"
          current_path={@current_path}
          icon="hero-user-circle"
          icon_active="hero-user-circle-solid"
          label="Perfil"
          active={String.starts_with?(@current_path, "/settings")}
        />
      </div>
    </nav>
    """
  end

  attr :navigate, :string, required: true
  attr :current_path, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :rest, :global

  def dropdown_item(assigns) do
    ~H"""
    <.session_link
      path={@navigate}
      current_path={@current_path}
      class="flex min-h-11 items-center gap-2.5 px-4 py-2 text-sm text-text-secondary transition-colors hover:bg-surface-hover/50 hover:text-text-primary"
      {@rest}
    >
      <.icon name={@icon} class="size-4" />
      <span>{@label}</span>
    </.session_link>
    """
  end

  attr :path, :string, required: true
  attr :current_path, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  slot :inner_block, required: true

  def session_link(assigns) do
    assigns =
      assign(
        assigns,
        :same_session?,
        LiveSessionNavigation.same_session?(assigns.current_path, assigns.path)
      )

    ~H"""
    <.link
      :if={@same_session?}
      navigate={@path}
      class={@class}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    <.link
      :if={!@same_session?}
      href={@path}
      class={@class}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end
end
