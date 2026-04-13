defmodule StreamixWeb.Content.NavigationComponents do
  @moduledoc "Navigation and tabs"
  use Phoenix.Component
  use StreamixWeb, :verified_routes
  import StreamixWeb.CoreComponents
  import StreamixWeb.Content.HelperComponents

  # ============================================
  # Source Tabs — Segmented Control
  # ============================================

  @doc """
  Segmented control for switching between IPTV and GIndex content sources.
  Compact Apple-style toggle with subtle glass background.
  """
  attr :selected, :string, required: true
  attr :path, :string, default: "/browse/movies"
  attr :iptv_path, :string, default: nil
  attr :gindex_path, :string, default: nil

  def source_tabs(assigns) do
    assigns =
      assigns
      |> assign_new(:iptv_target, fn ->
        path = assigns[:iptv_path] || assigns.path
        browse_path(path, "iptv")
      end)
      |> assign_new(:gindex_target, fn ->
        path = assigns[:gindex_path] || assigns.path
        browse_path(path, "gindex")
      end)

    ~H"""
    <nav class="segmented-control">
      <.link
        navigate={@iptv_target}
        class={["segmented-control__item", @selected == "iptv" && "segmented-control__item--active"]}
      >
        <.icon name="hero-signal" class="size-3.5" />
        <span>IPTV</span>
      </.link>
      <.link
        navigate={@gindex_target}
        class={["segmented-control__item", @selected == "gindex" && "segmented-control__item--active"]}
      >
        <.icon name="hero-cloud" class="size-3.5" />
        <span>GDrive</span>
      </.link>
    </nav>
    """
  end

  # ============================================
  # Browse Tabs — Underline Style
  # ============================================

  @doc """
  Content type tabs with animated underline indicator.
  Netflix-inspired minimal tab navigation.
  """
  attr :selected, :atom, required: true, values: [:live, :movies, :series, :animes]
  attr :counts, :map, default: %{}
  attr :source, :string, default: "iptv"

  def browse_tabs(assigns) do
    ~H"""
    <nav class="content-nav">
      <.browse_tab_item
        :if={@source == "gindex"}
        href={browse_path("/browse/animes", @source)}
        icon="hero-sparkles"
        label="Animes"
        count={@counts[:animes]}
        selected={@selected == :animes}
      />
      <.browse_tab_item
        :if={@source != "gindex"}
        href={browse_path("/browse", @source)}
        icon="hero-tv"
        label="Ao Vivo"
        count={@counts[:live]}
        selected={@selected == :live}
      />
      <.browse_tab_item
        href={browse_path("/browse/movies", @source)}
        icon="hero-film"
        label="Filmes"
        count={@counts[:movies]}
        selected={@selected == :movies}
      />
      <.browse_tab_item
        href={browse_path("/browse/series", @source)}
        icon="hero-video-camera"
        label="Séries"
        count={@counts[:series]}
        selected={@selected == :series}
      />
    </nav>
    """
  end

  defp browse_tab_item(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={["content-nav__tab", @selected && "content-nav__tab--active"]}
    >
      <.icon name={@icon} class="size-4" />
      <span>{@label}</span>
      <span :if={@count && @count > 0} class="content-nav__count hidden sm:inline">
        {format_count(@count)}
      </span>
    </.link>
    """
  end

  # ============================================
  # Content Tabs — Provider context (underline)
  # ============================================

  @doc """
  Content type tabs for provider-scoped views.
  Same underline style as browse_tabs.
  """
  attr :selected, :atom, required: true, values: [:live, :movies, :series]
  attr :provider_id, :any, required: true
  attr :counts, :map, default: %{}

  def content_tabs(assigns) do
    ~H"""
    <nav class="content-nav">
      <.link
        navigate={~p"/providers/#{@provider_id}"}
        class={["content-nav__tab", @selected == :live && "content-nav__tab--active"]}
      >
        <.icon name="hero-tv" class="size-4" />
        <span>Ao Vivo</span>
        <span :if={@counts[:live]} class="content-nav__count hidden sm:inline">
          {format_count(@counts.live)}
        </span>
      </.link>
      <.link
        navigate={~p"/providers/#{@provider_id}/movies"}
        class={["content-nav__tab", @selected == :movies && "content-nav__tab--active"]}
      >
        <.icon name="hero-film" class="size-4" />
        <span>Filmes</span>
        <span :if={@counts[:movies]} class="content-nav__count hidden sm:inline">
          {format_count(@counts.movies)}
        </span>
      </.link>
      <.link
        navigate={~p"/providers/#{@provider_id}/series"}
        class={["content-nav__tab", @selected == :series && "content-nav__tab--active"]}
      >
        <.icon name="hero-video-camera" class="size-4" />
        <span>Séries</span>
        <span :if={@counts[:series]} class="content-nav__count hidden sm:inline">
          {format_count(@counts.series)}
        </span>
      </.link>
    </nav>
    """
  end

  # ============================================
  # Section Header (unchanged)
  # ============================================

  @doc """
  Renders a section header with title, icon, filter dropdowns, and "Ver mais" link.
  """
  attr :title, :string, required: true
  attr :icon, :string, default: nil
  attr :icon_class, :string, default: "text-yellow-500"
  attr :genre_filters, :list, default: []
  attr :period_filters, :list, default: []
  attr :selected_genre, :string, default: "all"
  attr :selected_period, :any, default: 7
  attr :on_genre_change, :string, default: nil
  attr :on_period_change, :string, default: nil
  attr :see_more_path, :string, default: nil
  attr :ai_powered, :boolean, default: false

  def section_header(assigns) do
    ~H"""
    <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2 sm:gap-0 mb-3 sm:mb-4">
      <div class="flex items-center gap-2">
        <h2 class="flex items-center gap-2 text-base sm:text-xl font-semibold text-text-primary">
          <.icon :if={@icon} name={@icon} class={["size-4 sm:size-5", @icon_class]} />
          {@title}
        </h2>
        <span
          :if={@ai_powered}
          class="px-1.5 py-0.5 text-[9px] font-bold rounded bg-gradient-to-r from-purple-600 to-pink-600 text-white"
        >
          AI
        </span>
      </div>

      <div class="flex items-center gap-2 overflow-x-auto scrollbar-hide">
        <div :if={@genre_filters != [] and @on_genre_change} class="relative">
          <select
            phx-change={@on_genre_change}
            name="genre"
            class="appearance-none bg-surface hover:bg-surface-hover text-text-primary text-xs sm:text-sm px-2 sm:px-3 py-1 sm:py-1.5 pr-6 sm:pr-8 rounded-md border border-border cursor-pointer focus:outline-none focus:ring-1 focus:ring-brand"
          >
            <option
              :for={{value, label} <- @genre_filters}
              value={value}
              selected={@selected_genre == value}
            >
              {label}
            </option>
          </select>
          <.icon
            name="hero-chevron-down-mini"
            class="absolute right-1.5 sm:right-2 top-1/2 -translate-y-1/2 size-3 sm:size-4 text-text-muted pointer-events-none"
          />
        </div>

        <div :if={@period_filters != [] and @on_period_change} class="relative">
          <select
            phx-change={@on_period_change}
            name="period"
            class="appearance-none bg-surface hover:bg-surface-hover text-text-primary text-xs sm:text-sm px-2 sm:px-3 py-1 sm:py-1.5 pr-6 sm:pr-8 rounded-md border border-border cursor-pointer focus:outline-none focus:ring-1 focus:ring-brand"
          >
            <option
              :for={{days, label} <- @period_filters}
              value={days || "all"}
              selected={@selected_period == days}
            >
              {label}
            </option>
          </select>
          <.icon
            name="hero-chevron-down-mini"
            class="absolute right-1.5 sm:right-2 top-1/2 -translate-y-1/2 size-3 sm:size-4 text-text-muted pointer-events-none"
          />
        </div>

        <.link
          :if={@see_more_path}
          navigate={@see_more_path}
          class="text-xs sm:text-sm text-text-muted hover:text-brand transition-colors whitespace-nowrap flex-shrink-0"
        >
          Ver mais <span class="hidden sm:inline">→</span>
        </.link>
      </div>
    </div>
    """
  end

  # ============================================
  # Helpers
  # ============================================

  defp browse_path(path, "iptv"), do: path
  defp browse_path(path, "gindex"), do: path <> "?source=gindex"
  defp browse_path(path, _), do: path
end
