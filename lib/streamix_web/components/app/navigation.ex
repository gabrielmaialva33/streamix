defmodule StreamixWeb.App.Navigation do
  @moduledoc """
  Navigation components shared across the web app shell.
  """

  use Phoenix.Component
  use Gettext, backend: StreamixWeb.Gettext

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
        "mobile-bottom-tab flex min-h-11 min-w-0 flex-col items-center justify-center py-1 transition-colors touch-manipulation",
        @active && "text-brand",
        !@active && "text-text-secondary active:text-text-primary"
      ]}
    >
      <span class={[
        "flex items-center justify-center rounded-xl transition-all",
        @active && "bg-brand/15 px-3 py-0.5",
        !@active && "px-2 py-0.5"
      ]}>
        <.icon
          name={if @active, do: @icon_active, else: @icon}
          class="size-[19px] transition-transform"
        />
      </span>
      <span class="mt-0.5 text-[9px] font-medium leading-none">{@label}</span>
    </.session_link>
    """
  end

  attr :home_path, :string, required: true
  attr :current_path, :string, required: true

  def mobile_bottom_nav(assigns) do
    ~H"""
    <nav
      id="mobile-bottom-nav"
      aria-label={gettext("Navegação principal")}
      class="mobile-bottom-nav fixed inset-x-0 bottom-0 z-40 md:hidden"
    >
      <div class="grid h-[3.75rem] grid-cols-5 items-stretch">
        <.bottom_tab
          id="mobile-tab-home"
          path={@home_path}
          current_path={@current_path}
          icon="hero-home"
          icon_active="hero-home-solid"
          label={gettext("Início")}
          active={@current_path in ["/", "/home"]}
        />
        <.bottom_tab
          id="mobile-tab-catalog"
          path="/browse"
          current_path={@current_path}
          icon="hero-squares-2x2"
          icon_active="hero-squares-2x2-solid"
          label={gettext("Catálogo")}
          active={String.starts_with?(@current_path, "/browse")}
        />
        <.bottom_tab
          id="mobile-tab-search"
          path="/search"
          current_path={@current_path}
          icon="hero-magnifying-glass"
          icon_active="hero-magnifying-glass-solid"
          label={gettext("Busca")}
          active={String.starts_with?(@current_path, "/search")}
        />
        <.bottom_tab
          id="mobile-tab-favorites"
          path="/favorites"
          current_path={@current_path}
          icon="hero-heart"
          icon_active="hero-heart-solid"
          label={gettext("Minha lista")}
          active={String.starts_with?(@current_path, "/favorites")}
        />
        <button
          id="mobile-tab-more"
          type="button"
          popovertarget="mobile-more-sheet"
          aria-label={gettext("Mais")}
          aria-current={more_active?(@current_path) && "page"}
          class={[
            "mobile-bottom-tab flex min-h-11 min-w-0 flex-col items-center justify-center py-1 transition-colors touch-manipulation",
            more_active?(@current_path) && "text-brand",
            !more_active?(@current_path) && "text-text-secondary active:text-text-primary"
          ]}
        >
          <span class={[
            "flex items-center justify-center rounded-xl transition-all",
            more_active?(@current_path) && "bg-brand/15 px-3 py-0.5",
            !more_active?(@current_path) && "px-2 py-0.5"
          ]}>
            <.icon name="hero-ellipsis-horizontal-circle" class="size-[19px]" />
          </span>
          <span class="mt-0.5 text-[9px] font-medium leading-none">{gettext("Mais")}</span>
        </button>
      </div>
      <.more_sheet current_path={@current_path} />
    </nav>
    """
  end

  # What the desktop header offers beyond the four tabs, so the phone shell
  # reaches the same places. A native popover: tap outside or Esc closes it.
  @more_links [
    {"/guide", "hero-calendar-days", "Guia de programação"},
    {"/torrent", "hero-bolt", "Torrents"},
    {"/party", "hero-users", "Assistir juntos"},
    {"/history", "hero-clock", "Histórico"},
    {"/providers", "hero-server-stack", "Meus provedores"},
    {"/settings", "hero-cog-6-tooth", "Configurações"}
  ]

  attr :current_path, :string, required: true

  defp more_sheet(assigns) do
    assigns = assign(assigns, :links, @more_links)

    ~H"""
    <div
      id="mobile-more-sheet"
      popover
      phx-hook=".MoreSheet"
      aria-label={gettext("Mais")}
      class="inset-x-0 top-auto bottom-0 m-0 h-auto max-h-[80dvh] w-full max-w-none overflow-y-auto rounded-t-2xl border-0 border-t border-border bg-surface p-0 pb-[env(safe-area-inset-bottom,0px)] text-text-primary shadow-dropdown backdrop:bg-black/50 md:hidden"
    >
      <div class="flex items-center justify-between pt-2 pr-2 pl-5">
        <p class="text-xs font-semibold uppercase tracking-wide text-text-secondary">
          {gettext("Mais")}
        </p>
        <button
          type="button"
          popovertarget="mobile-more-sheet"
          popovertargetaction="hide"
          aria-label={gettext("Fechar")}
          class="flex size-11 items-center justify-center rounded-xl text-text-secondary active:bg-surface-hover"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>
      <ul class="pb-2">
        <li :for={{path, icon, label} <- @links}>
          <.session_link
            id={"mobile-more-" <> String.trim_leading(path, "/")}
            path={path}
            current_path={@current_path}
            aria-current={String.starts_with?(@current_path, path) && "page"}
            class={[
              "flex min-h-12 items-center gap-3 px-5 py-3 text-sm font-medium transition-colors active:bg-surface-hover",
              String.starts_with?(@current_path, path) && "text-brand",
              !String.starts_with?(@current_path, path) && "text-text-primary"
            ]}
          >
            <.icon name={icon} class="size-5 text-text-secondary" />
            <span>{label}</span>
          </.session_link>
        </li>
      </ul>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".MoreSheet">
      export default {
        mounted() {
          // A live navigation patches this element in place, so it would
          // stay open on the next page: close it when a link is chosen.
          this.onClick = (event) => {
            if (event.target.closest("a") && this.el.matches(":popover-open")) this.el.hidePopover()
          }
          this.el.addEventListener("click", this.onClick)
        },
        destroyed() {
          this.el.removeEventListener("click", this.onClick)
        }
      }
    </script>
    """
  end

  defp more_active?(current_path) do
    Enum.any?(@more_links, fn {path, _icon, _label} -> String.starts_with?(current_path, path) end)
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
