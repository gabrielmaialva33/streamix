defmodule StreamixWeb.Content.CarouselComponents do
  @moduledoc "Carousel, grid, and hero components"
  use Phoenix.Component
  use StreamixWeb, :verified_routes
  import StreamixWeb.CoreComponents
  import StreamixWeb.Content.CardComponents
  import StreamixWeb.Content.HelperComponents

  @doc """
  Renders a responsive content grid.
  """
  attr :id, :string, required: true
  attr :items, :list, required: true
  attr :type, :atom, required: true, values: [:movie, :series]
  attr :favorites_map, :map, default: %{}

  def content_grid(assigns) do
    ~H"""
    <div
      id={@id}
      phx-update="stream"
      class="grid gap-3 sm:gap-4 grid-cols-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6"
    >
      <div :for={{dom_id, item} <- @items} id={dom_id}>
        <.movie_card
          :if={@type == :movie}
          movie={item}
          is_favorite={Map.get(@favorites_map, item.id, false)}
        />
        <.series_card
          :if={@type == :series}
          series={item}
          is_favorite={Map.get(@favorites_map, item.id, false)}
        />
      </div>
    </div>
    """
  end

  @doc """
  Renders a horizontal content carousel with scroll-snap.
  """
  attr :title, :string, required: true
  attr :items, :list, required: true
  attr :type, :atom, required: true, values: [:movie, :series, :channel]
  attr :see_all_path, :string, default: nil

  def content_carousel(assigns) do
    ~H"""
    <section :if={length(@items) > 0} class="space-y-3 sm:space-y-4">
      <div class="flex items-center justify-between px-[4%]">
        <h2 class="text-base sm:text-xl font-bold text-text-primary">{@title}</h2>
        <.link
          :if={@see_all_path}
          navigate={@see_all_path}
          class="flex items-center gap-1 px-3 py-1.5 text-sm text-text-muted hover:text-brand transition-colors rounded-xl hover:bg-surface-hover/40"
        >
          Ver tudo <.icon name="hero-chevron-right" class="size-4" />
        </.link>
      </div>

      <div class="flex gap-3 sm:gap-4 overflow-x-auto pb-2 scrollbar-hide scroll-smooth px-[4%]">
        <div :for={item <- @items} class="flex-shrink-0 w-28 sm:w-40 lg:w-44">
          <.movie_card :if={@type == :movie} movie={item} show_favorite={false} />
          <.series_card :if={@type == :series} series={item} show_favorite={false} />
        </div>
      </div>
    </section>
    """
  end

  @doc """
  Renders a hero banner for featured content.
  """
  attr :content, :map, required: true
  attr :type, :atom, required: true, values: [:movie, :series]
  attr :on_play, :string, default: "play"
  attr :on_details, :string, default: "show_details"

  def content_hero(assigns) do
    ~H"""
    <%!--
      iOS Safari: dvh stops the detail hero from recomputing height when the
      URL bar collapses mid-scroll — the backdrop image would otherwise crop
      shift and cause a visible layout shake on iPhone.
    --%>
    <div class="relative h-[55dvh] sm:h-[60dvh] min-h-[400px] bg-surface-hover overflow-hidden">
      <img
        :if={Map.get(@content, :backdrop) || Map.get(@content, :cover)}
        src={Map.get(@content, :backdrop) || Map.get(@content, :cover)}
        alt={@content.name}
        class="w-full h-full object-cover"
        fetchpriority="high"
        decoding="async"
      />
      <%!-- Multi-layer gradient for cinematic feel --%>
      <div class="absolute inset-0 bg-gradient-to-t from-background via-background/60 to-transparent" />
      <div class="absolute inset-0 bg-gradient-to-r from-background/80 via-transparent to-transparent" />

      <div class="absolute bottom-0 left-0 right-0 p-6 sm:p-8 lg:p-12 px-[4%]">
        <div class="max-w-2xl space-y-3 sm:space-y-4">
          <h1 class="text-2xl sm:text-4xl lg:text-5xl font-bold text-white leading-tight">
            {Map.get(@content, :title) || @content.name}
          </h1>

          <div class="flex flex-wrap items-center gap-3 text-sm text-white/70">
            <span :if={Map.get(@content, :year)} class="font-medium">{@content.year}</span>
            <span :if={Map.get(@content, :rating)} class="flex items-center gap-1 text-warning">
              <.icon name="hero-star-solid" class="size-4" />
              {format_rating(@content.rating)}
            </span>
            <span :if={Map.get(@content, :genres, []) != []}>{format_genre_names(@content)}</span>
            <span :if={Map.get(@content, :duration_secs)}>
              {format_duration(@content.duration_secs)}
            </span>
          </div>

          <p
            :if={Map.get(@content, :plot)}
            class="text-sm sm:text-base text-white/60 line-clamp-2 sm:line-clamp-3 max-w-xl"
          >
            {@content.plot}
          </p>

          <div class="flex items-center gap-3 pt-1 sm:pt-2">
            <button
              type="button"
              phx-click={@on_play}
              phx-value-id={@content.id}
              class="inline-flex items-center gap-2 px-5 sm:px-8 py-2.5 sm:py-3 bg-white text-black font-semibold rounded-lg hover:bg-white/90 transition-all shadow-card hover:shadow-card-hover hover:scale-[1.02] active:scale-[0.98] focus:outline-none focus:ring-2 focus:ring-brand"
            >
              <.icon name="hero-play-solid" class="size-5" /> Assistir
            </button>
            <button
              type="button"
              phx-click={@on_details}
              phx-value-id={@content.id}
              class="inline-flex items-center gap-2 px-5 sm:px-8 py-2.5 sm:py-3 glass text-white font-semibold rounded-lg hover:bg-white/20 transition-all focus:outline-none focus:ring-2 focus:ring-brand"
            >
              <.icon name="hero-information-circle" class="size-5" /> Mais Info
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a "Para Você" AI recommendations section.
  """
  attr :recommendations, :list, required: true
  attr :on_play, :string, default: "play_movie"
  attr :on_details, :string, default: "show_details"

  def for_you_section(assigns) do
    ~H"""
    <section class="px-[4%]">
      <div class="flex items-center justify-between mb-3 sm:mb-4">
        <h2 class="flex items-center gap-2 text-base sm:text-xl font-semibold text-text-primary">
          <.icon name="hero-sparkles-solid" class="size-4 sm:size-5 text-warning" /> Para Você
        </h2>
      </div>

      <%= if @recommendations == [] do %>
        <div class="flex flex-col items-center justify-center py-12 sm:py-16 rounded-lg border border-glass-border bg-surface-elevated/30">
          <.icon name="hero-sparkles" class="size-12 sm:size-16 text-text-muted mb-4" />
          <h3 class="text-base sm:text-lg font-medium text-text-secondary mb-2">
            Ainda estamos conhecendo você
          </h3>
          <p class="text-sm text-text-muted text-center max-w-md px-4">
            Continue assistindo para receber recomendações personalizadas baseadas no seu gosto.
          </p>
        </div>
      <% else %>
        <%!-- Mobile: 3-column grid --%>
        <div class="grid grid-cols-3 gap-2 sm:hidden">
          <.movie_card
            :for={item <- Enum.take(@recommendations, 6)}
            movie={item}
            show_favorite={false}
            on_play={@on_play}
            on_details={@on_details}
          />
        </div>
        <%!-- Desktop: horizontal scroll --%>
        <div class="hidden sm:flex sm:gap-4 sm:overflow-x-auto py-1 sm:py-2 scrollbar-hide scroll-smooth">
          <div :for={item <- @recommendations} class="flex-shrink-0 w-[160px] lg:w-[180px]">
            <.movie_card
              movie={item}
              show_favorite={false}
              on_play={@on_play}
              on_details={@on_details}
            />
          </div>
        </div>
      <% end %>
    </section>
    """
  end
end
