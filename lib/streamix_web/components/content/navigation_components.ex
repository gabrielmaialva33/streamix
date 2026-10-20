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
  # Torrent is intentionally absent: it has its own top-level screen
  # (`/torrent`) reached from the main nav, not a source that shares this
  # catalog grid. The segmented control is for IPTV/GDrive only.
  attr :selected, :string, required: true
  attr :path, :string, default: "/browse/movies"
  attr :iptv_path, :string, default: nil
  attr :gindex_path, :string, default: nil
  attr :query_params, :map, default: %{}

  def source_tabs(assigns) do
    assigns =
      assigns
      |> assign_new(:iptv_target, fn ->
        path = assigns[:iptv_path] || assigns.path
        browse_path(path, "iptv", assigns.query_params)
      end)
      |> assign_new(:gindex_target, fn ->
        path = assigns[:gindex_path] || assigns.path
        browse_path(path, "gindex", Map.delete(assigns.query_params, "provider"))
      end)

    ~H"""
    <div class="catalog-source">
      <span class="text-xs text-text-secondary">Catálogo:</span>
      <nav class="segmented-control" aria-label="Escolher catálogo">
        <.link
          navigate={@iptv_target}
          class={["segmented-control__item", @selected == "iptv" && "segmented-control__item--active"]}
        >
          <.icon name="hero-signal" class="size-3.5" />
          <span>IPTV</span>
        </.link>
        <.link
          navigate={@gindex_target}
          class={[
            "segmented-control__item",
            @selected == "gindex" && "segmented-control__item--active"
          ]}
        >
          <.icon name="hero-cloud" class="size-3.5" />
          <span>Google Drive</span>
        </.link>
      </nav>
    </div>
    """
  end

  # ============================================
  # Browse Tabs — Underline Style
  # ============================================

  @doc """
  Content type tabs with animated underline indicator.
  Netflix-inspired minimal tab navigation.
  """
  attr :selected, :atom, required: true, values: [:live, :movies, :series, :animes, :reels]
  attr :counts, :map, default: %{}
  attr :source, :string, default: "iptv"
  attr :query_params, :map, default: %{}

  def browse_tabs(assigns) do
    ~H"""
    <nav
      id="catalog-type-tabs"
      phx-hook=".CatalogTabs"
      class="content-nav"
      aria-label={"Tipos do catálogo #{if @source == "gindex", do: "Google Drive", else: "IPTV"}"}
    >
      <.browse_tab_item
        :if={@source == "gindex"}
        href={browse_path("/browse/animes", @source, @query_params)}
        icon="hero-sparkles"
        label="Animes"
        count={@counts[:animes]}
        selected={@selected == :animes}
      />
      <.browse_tab_item
        :if={@source != "gindex"}
        href={browse_path("/browse", @source, @query_params)}
        icon="hero-tv"
        label="Ao Vivo"
        count={@counts[:live]}
        selected={@selected == :live}
      />
      <.browse_tab_item
        href={browse_path("/browse/movies", @source, @query_params)}
        icon="hero-film"
        label="Filmes"
        count={@counts[:movies]}
        selected={@selected == :movies}
      />
      <.browse_tab_item
        href={browse_path("/browse/series", @source, @query_params)}
        icon="hero-video-camera"
        label="Séries"
        count={@counts[:series]}
        selected={@selected == :series}
      />
      <%!-- Short dramas exist only in IPTV catalogs and ignore provider/search filters. --%>
      <.browse_tab_item
        :if={@source != "gindex"}
        id="browse-tab-reels"
        href={~p"/browse/reels"}
        icon="hero-device-phone-mobile"
        label="Dramas curtos"
        count={@counts[:reels]}
        selected={@selected == :reels}
      />
    </nav>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CatalogTabs">
      export default {
        mounted() { this.revealActive() },
        updated() { this.revealActive() },
        revealActive() {
          const active = this.el.querySelector('[aria-current="page"]')
          if (!active) return
          const bounds = this.el.getBoundingClientRect()
          const tab = active.getBoundingClientRect()
          if (tab.left < bounds.left) this.el.scrollLeft -= bounds.left - tab.left
          else if (tab.right > bounds.right) this.el.scrollLeft += tab.right - bounds.right
        }
      }
    </script>
    """
  end

  attr :id, :string, default: nil
  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :count, :integer, default: nil
  attr :selected, :boolean, default: false

  defp browse_tab_item(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@href}
      aria-current={@selected && "page"}
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
        <span :if={@counts[:live] && @counts[:live] > 0} class="content-nav__count hidden sm:inline">
          {format_count(@counts.live)}
        </span>
      </.link>
      <.link
        navigate={~p"/providers/#{@provider_id}/movies"}
        class={["content-nav__tab", @selected == :movies && "content-nav__tab--active"]}
      >
        <.icon name="hero-film" class="size-4" />
        <span>Filmes</span>
        <span
          :if={@counts[:movies] && @counts[:movies] > 0}
          class="content-nav__count hidden sm:inline"
        >
          {format_count(@counts.movies)}
        </span>
      </.link>
      <.link
        navigate={~p"/providers/#{@provider_id}/series"}
        class={["content-nav__tab", @selected == :series && "content-nav__tab--active"]}
      >
        <.icon name="hero-video-camera" class="size-4" />
        <span>Séries</span>
        <span
          :if={@counts[:series] && @counts[:series] > 0}
          class="content-nav__count hidden sm:inline"
        >
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
  Renders a section header with title, icon, filter dropdowns, and "Ver todos" link.
  """
  attr :title, :string, required: true
  attr :icon, :string, default: nil
  attr :icon_class, :string, default: "text-warning"
  attr :genre_filters, :list, default: []
  attr :period_filters, :list, default: []
  attr :selected_genre, :string, default: "all"
  attr :selected_period, :any, default: 7
  attr :on_genre_change, :string, default: nil
  attr :on_period_change, :string, default: nil
  attr :see_more_path, :string, default: nil
  attr :ai_powered, :boolean, default: false
  attr :id, :string, default: nil
  slot :actions

  def section_header(assigns) do
    ~H"""
    <div id={@id} class="mb-3 sm:mb-4 space-y-2">
      <div class="flex items-center justify-between gap-3">
        <h2 class="flex items-center gap-2 text-base sm:text-xl font-semibold text-text-primary">
          <.icon :if={@icon} name={@icon} class={["size-5 shrink-0", @icon_class]} />
          {@title}
          <.badge :if={@ai_powered} variant="brand" size="sm">IA</.badge>
        </h2>
        <div class="flex items-center gap-2 shrink-0">
          {render_slot(@actions)}
          <.button :if={@see_more_path} navigate={@see_more_path} variant="ghost" size="sm">Ver todos
          <.icon name="hero-chevron-right" class="size-4" /></.button>
        </div>
      </div>
      <div :if={@on_genre_change || @on_period_change} class="flex flex-wrap items-center gap-2">
        <form :if={@on_genre_change && @genre_filters != []} phx-change={@on_genre_change}>
          <StreamixWeb.App.Filters.filter_select
            id={"section-genre-#{@on_genre_change}"}
            name="genre"
            label="Filtrar por gênero"
            options={@genre_filters}
            value={@selected_genre}
          />
        </form>
        <form :if={@on_period_change && @period_filters != []} phx-change={@on_period_change}>
          <StreamixWeb.App.Filters.filter_select
            id={"section-period-#{@on_period_change}"}
            name="period"
            label="Filtrar período"
            options={@period_filters}
            value={@selected_period}
          />
        </form>
      </div>
    </div>
    """
  end

  # ============================================
  # Helpers
  # ============================================

  defp browse_path(path, "iptv", params), do: append_query(path, params)

  defp browse_path(path, "gindex", params) do
    append_query(path, Map.put(params, "source", "gindex"))
  end

  defp browse_path(path, _, params), do: append_query(path, params)

  defp append_query(path, params) when map_size(params) == 0, do: path
  defp append_query(path, params), do: path <> "?" <> URI.encode_query(params)
end
