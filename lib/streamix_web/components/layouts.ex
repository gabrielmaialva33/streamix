defmodule StreamixWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use StreamixWeb, :html

  import StreamixWeb.CoreComponents

  embed_templates "layouts/*"

  @doc """
  Renders your app layout with sidebar navigation.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :any,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="drawer lg:drawer-open">
      <input id="sidebar-drawer" type="checkbox" class="drawer-toggle" />

      <div class="drawer-content flex flex-col min-h-screen">
        <.mobile_header />

        <main class="flex-1 p-4 lg:p-6">
          {render_slot(@inner_block)}
        </main>
      </div>

      <.sidebar current_scope={@current_scope} />
    </div>

    <.flash_group flash={@flash} />
    """
  end

  defp mobile_header(assigns) do
    ~H"""
    <header class="navbar bg-base-200 lg:hidden">
      <div class="flex-none">
        <label for="sidebar-drawer" class="btn btn-square btn-ghost drawer-button">
          <.icon name="hero-bars-3" class="size-6" />
        </label>
      </div>
      <div class="flex-1">
        <.link navigate={~p"/"} class="btn btn-ghost text-xl">
          <.icon name="hero-play-circle-solid" class="size-6 text-primary" /> Streamix
        </.link>
      </div>
      <div class="flex-none">
        <.theme_toggle />
      </div>
    </header>
    """
  end

  attr :current_scope, :map, default: nil

  defp sidebar(assigns) do
    ~H"""
    <div class="drawer-side z-40">
      <label for="sidebar-drawer" aria-label="close sidebar" class="drawer-overlay"></label>

      <aside class="bg-base-200 min-h-full w-64 flex flex-col">
        <div class="p-4 border-b border-base-300">
          <.link navigate={~p"/"} class="flex items-center gap-2 text-xl font-bold">
            <.icon name="hero-play-circle-solid" class="size-8 text-primary" /> Streamix
          </.link>
        </div>

        <nav class="flex-1 p-4">
          <ul class="menu menu-lg gap-1">
            <li>
              <.link navigate={~p"/"} class="flex items-center gap-3">
                <.icon name="hero-home" class="size-5" /> Dashboard
              </.link>
            </li>
            <li>
              <.link navigate={~p"/channels"} class="flex items-center gap-3">
                <.icon name="hero-tv" class="size-5" /> Channels
              </.link>
            </li>
            <li>
              <.link navigate={~p"/favorites"} class="flex items-center gap-3">
                <.icon name="hero-heart" class="size-5" /> Favorites
              </.link>
            </li>
            <li>
              <.link navigate={~p"/history"} class="flex items-center gap-3">
                <.icon name="hero-clock" class="size-5" /> History
              </.link>
            </li>
          </ul>

          <div class="divider my-4"></div>

          <ul class="menu menu-lg gap-1">
            <li>
              <.link navigate={~p"/providers"} class="flex items-center gap-3">
                <.icon name="hero-server" class="size-5" /> Providers
              </.link>
            </li>
            <li>
              <.link navigate={~p"/settings"} class="flex items-center gap-3">
                <.icon name="hero-cog-6-tooth" class="size-5" /> Settings
              </.link>
            </li>
          </ul>
        </nav>

        <div class="p-4 border-t border-base-300">
          <div class="flex items-center justify-between">
            <span class="text-sm text-base-content/60">Theme</span>
            <.theme_toggle />
          </div>
        </div>
      </aside>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
