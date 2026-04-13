defmodule StreamixWeb.Content.NavigationComponents do
  @moduledoc "Navigation and tabs"
  use Phoenix.Component
  use StreamixWeb, :verified_routes
  import StreamixWeb.CoreComponents
  import StreamixWeb.AppComponents
  # Shared helpers and internal formats
  import StreamixWeb.Content.HelperComponents
  alias StreamixWeb.Helpers.ImageProxy

  @doc """
  Renders content type navigation tabs.

  ## Attributes

    * `:selected` - Currently selected tab (:live, :movies, :series)
    * `:provider_id` - Provider ID for navigation links
    * `:counts` - Map with content counts %{live: n, movies: n, series: n}

  ## Examples

      <.content_tabs selected={:movies} provider_id={@provider.id} counts={@counts} />
  """
  attr :selected, :atom, required: true, values: [:live, :movies, :series]
  attr :provider_id, :any, required: true
  attr :counts, :map, default: %{}

  def content_tabs(assigns) do
    ~H"""
    <div class="flex bg-surface rounded-lg p-1 gap-1 overflow-x-auto scrollbar-hide">
      <.link
        navigate={~p"/providers/#{@provider_id}"}
        class={[
          "flex items-center gap-1.5 sm:gap-2 px-3 sm:px-4 py-1.5 sm:py-2 rounded-md text-xs sm:text-sm font-medium transition-colors whitespace-nowrap flex-shrink-0",
          @selected == :live && "bg-brand text-white",
          @selected != :live && "text-text-secondary hover:text-text-primary hover:bg-surface-hover"
        ]}
      >
        <.icon name="hero-tv" class="size-3.5 sm:size-4" />
        <span>Ao Vivo</span>
        <span :if={@counts[:live]} class="px-1.5 py-0.5 text-[10px] sm:text-xs rounded bg-black/20">
          {format_count(@counts.live)}
        </span>
      </.link>
      <.link
        navigate={~p"/providers/#{@provider_id}/movies"}
        class={[
          "flex items-center gap-1.5 sm:gap-2 px-3 sm:px-4 py-1.5 sm:py-2 rounded-md text-xs sm:text-sm font-medium transition-colors whitespace-nowrap flex-shrink-0",
          @selected == :movies && "bg-brand text-white",
          @selected != :movies && "text-text-secondary hover:text-text-primary hover:bg-surface-hover"
        ]}
      >
        <.icon name="hero-film" class="size-3.5 sm:size-4" />
        <span>Filmes</span>
        <span :if={@counts[:movies]} class="px-1.5 py-0.5 text-[10px] sm:text-xs rounded bg-black/20">
          {format_count(@counts.movies)}
        </span>
      </.link>
      <.link
        navigate={~p"/providers/#{@provider_id}/series"}
        class={[
          "flex items-center gap-1.5 sm:gap-2 px-3 sm:px-4 py-1.5 sm:py-2 rounded-md text-xs sm:text-sm font-medium transition-colors whitespace-nowrap flex-shrink-0",
          @selected == :series && "bg-brand text-white",
          @selected != :series && "text-text-secondary hover:text-text-primary hover:bg-surface-hover"
        ]}
      >
        <.icon name="hero-video-camera" class="size-3.5 sm:size-4" />
        <span>Séries</span>
        <span :if={@counts[:series]} class="px-1.5 py-0.5 text-[10px] sm:text-xs rounded bg-black/20">
          {format_count(@counts.series)}
        </span>
      </.link>
    </div>
    """
  end

  @doc """
  Renders navigation tabs for the global browse catalog.

  ## Attributes

    * `:selected` - Currently selected tab (:live, :movies, :series, :animes)
    * `:counts` - Map with content counts %{live: n, movies: n, series: n, animes: n}
    * `:source` - Content source ("iptv" or "gindex"). When "gindex", shows Animes instead of Ao Vivo.

  ## Examples

      <.browse_tabs selected={:movies} counts={%{live: 100, movies: 500, series: 50}} />
      <.browse_tabs selected={:animes} source="gindex" counts={%{animes: 200, movies: 500, series: 50}} />
  """
  attr :selected, :atom, required: true, values: [:live, :movies, :series, :animes]
  attr :counts, :map, default: %{}
  attr :source, :string, default: "iptv"

  def browse_tabs(assigns) do
    ~H"""
    <div class="flex bg-surface rounded-lg p-1 gap-1 overflow-x-auto scrollbar-hide">
      <.browse_tab
        :if={@source == "gindex"}
        href={browse_path("/browse/animes", @source)}
        icon="hero-sparkles"
        label="Animes"
        count={@counts[:animes]}
        selected={@selected == :animes}
      />
      <.browse_tab
        :if={@source != "gindex"}
        href={browse_path("/browse", @source)}
        icon="hero-tv"
        label="Ao Vivo"
        count={@counts[:live]}
        selected={@selected == :live}
      />
      <.browse_tab
        href={browse_path("/browse/movies", @source)}
        icon="hero-film"
        label="Filmes"
        count={@counts[:movies]}
        selected={@selected == :movies}
      />
      <.browse_tab
        href={browse_path("/browse/series", @source)}
        icon="hero-video-camera"
        label="Séries"
        count={@counts[:series]}
        selected={@selected == :series}
      />
    </div>
    """
  end

  defp browse_tab(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={[
        "flex items-center gap-1 sm:gap-2 px-3 sm:px-4 py-1.5 sm:py-2 rounded-md text-xs sm:text-sm font-medium transition-colors whitespace-nowrap flex-shrink-0",
        @selected && "bg-brand text-white",
        !@selected && "text-text-secondary hover:text-text-primary hover:bg-surface-hover"
      ]}
    >
      <.icon name={@icon} class="size-3.5 sm:size-4" />
      <span>{@label}</span>
      <span
        :if={@count && @count > 0}
        class="hidden sm:inline px-1 py-0.5 text-[9px] sm:text-xs rounded bg-black/20"
      >
        {format_count(@count)}
      </span>
    </.link>
    """
  end

  @doc """
  Renders source tabs for switching between IPTV and GIndex content.

  ## Attributes

    * `:selected` - Currently selected source ("iptv" or "gindex")
    * `:path` - Current path to preserve when switching sources
    * `:iptv_path` - Override path for IPTV tab (for animes which redirects to live)
    * `:gindex_path` - Override path for GDrive tab (for live which redirects to animes)

  ## Examples

      <.source_tabs selected="iptv" path="/browse/movies" />
      <.source_tabs selected="gindex" path="/browse/animes" iptv_path="/browse" />
  """
  attr :selected, :string, required: true
  attr :path, :string, default: "/browse/movies"

  attr :iptv_path, :string,
    default: nil,
    doc: "Override path for IPTV tab (for animes which redirects to live)"

  attr :gindex_path, :string,
    default: nil,
    doc: "Override path for GDrive tab (for live which redirects to animes)"

  def source_tabs(assigns) do
    # Compute target paths with overrides
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
    <div class="flex items-center bg-surface rounded-full p-0.5 gap-0.5">
      <.link
        navigate={@iptv_target}
        class={[
          "flex items-center gap-1 px-2.5 py-1.5 sm:px-4 sm:py-2 rounded-full text-xs sm:text-sm font-medium transition-all duration-200 whitespace-nowrap",
          @selected == "iptv" && "bg-brand text-white shadow-sm",
          @selected != "iptv" && "text-text-secondary hover:text-text-primary"
        ]}
      >
        <.icon name="hero-signal" class="size-3.5 sm:size-4" />
        <span>IPTV</span>
      </.link>
      <.link
        navigate={@gindex_target}
        class={[
          "flex items-center gap-1 px-2.5 py-1.5 sm:px-4 sm:py-2 rounded-full text-xs sm:text-sm font-medium transition-all duration-200 whitespace-nowrap",
          @selected == "gindex" && "bg-brand text-white shadow-sm",
          @selected != "gindex" && "text-text-secondary hover:text-text-primary"
        ]}
      >
        <.icon name="hero-cloud" class="size-3.5 sm:size-4" />
        <span>GDrive</span>
      </.link>
    </div>
    """
  end

  defp browse_path(path, "iptv"), do: path

  @doc """
  Renders a section header with title, icon, filter dropdowns, and "Ver mais" link.

  Used for AI-powered sections like "Em Alta Agora", "Séries Populares", etc.

  ## Attributes

    * `:title` - Section title (required)
    * `:icon` - Hero icon name (optional)
    * `:icon_class` - Additional classes for the icon
    * `:genre_filters` - List of {value, label} for genre dropdown
    * `:period_filters` - List of {days, label} for period dropdown
    * `:selected_genre` - Currently selected genre filter
    * `:selected_period` - Currently selected period filter
    * `:on_genre_change` - Event name for genre filter change
    * `:on_period_change` - Event name for period filter change
    * `:see_more_path` - Path for "Ver mais" link
    * `:ai_powered` - Show AI badge (default: false)

  ## Examples

      <.section_header
        title="Em Alta Agora"
        icon="hero-fire-solid"
        icon_class="text-orange-500"
        genre_filters={@genre_filters}
        selected_genre={@trending_genre}
        on_genre_change="filter_trending_genre"
        period_filters={@period_filters}
        selected_period={@trending_period}
        on_period_change="filter_trending_period"
        see_more_path={~p"/browse/movies"}
        ai_powered={true}
      />
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
        <!-- Genre Filter Dropdown -->
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
        
    <!-- Period Filter Dropdown -->
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
        
    <!-- Ver mais link -->
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
end
