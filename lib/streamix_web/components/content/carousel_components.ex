defmodule StreamixWeb.Content.CarouselComponents do
  @moduledoc "Carousel and grid components"
  use Phoenix.Component
  use StreamixWeb, :verified_routes
  import StreamixWeb.CoreComponents
  import StreamixWeb.AppComponents
  # Shared helpers and internal formats
  import StreamixWeb.Content.HelperComponents
  alias StreamixWeb.Helpers.ImageProxy

  @doc """
  Renders a content grid for movies or series.

  ## Attributes

    * `:id` - DOM ID for the grid
    * `:items` - Stream of items to render
    * `:type` - Type of content (:movie or :series)
    * `:favorites_map` - Map of item IDs to favorite status

  ## Examples

      <.content_grid id="movies" items={@streams.movies} type={:movie} />
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
      class="grid gap-4 grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6"
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
  Renders a horizontal content carousel.

  ## Attributes

    * `:title` - Carousel section title
    * `:items` - List of items to render
    * `:type` - Type of content (:movie, :series, or :channel)
    * `:see_all_path` - Path for "See all" link

  ## Examples

      <.content_carousel title="Continue Assistindo" items={@history} type={:movie} />
  """
  attr :title, :string, required: true
  attr :items, :list, required: true
  attr :type, :atom, required: true, values: [:movie, :series, :channel]
  attr :see_all_path, :string, default: nil

  def content_carousel(assigns) do
    ~H"""
    <section :if={length(@items) > 0} class="space-y-4">
      <div class="flex items-center justify-between">
        <h2 class="text-xl font-bold text-text-primary">{@title}</h2>
        <.link
          :if={@see_all_path}
          navigate={@see_all_path}
          class="flex items-center gap-1 px-3 py-1.5 text-sm text-text-secondary hover:text-text-primary hover:bg-surface-hover rounded-md transition-colors"
        >
          Ver tudo <.icon name="hero-arrow-right" class="size-4" />
        </.link>
      </div>

      <div class="flex gap-4 overflow-x-auto pb-4 scrollbar-hide scroll-smooth">
        <div :for={item <- @items} class="flex-shrink-0 w-36 sm:w-44">
          <.movie_card :if={@type == :movie} movie={item} show_favorite={false} />
          <.series_card :if={@type == :series} series={item} show_favorite={false} />
        </div>
      </div>
    </section>
    """
  end

  @doc """
  Renders a hero banner for featured content.

  ## Attributes

    * `:content` - The featured content
    * `:type` - Type of content (:movie or :series)
    * `:on_play` - Event name for play action
    * `:on_details` - Event name for details action

  ## Examples

      <.content_hero content={@featured_movie} type={:movie} />
  """
  attr :content, :map, required: true
  attr :type, :atom, required: true, values: [:movie, :series]
  attr :on_play, :string, default: "play"
  attr :on_details, :string, default: "show_details"

  def content_hero(assigns) do
    ~H"""
    <div class="relative h-[50vh] min-h-[400px] bg-surface-hover rounded-xl overflow-hidden">
      <img
        :if={Map.get(@content, :backdrop) || Map.get(@content, :cover)}
        src={Map.get(@content, :backdrop) || Map.get(@content, :cover)}
        alt={@content.name}
        class="w-full h-full object-cover"
      />
      <div class="absolute inset-0 bg-gradient-to-t from-background via-background/50 to-transparent" />

      <div class="absolute bottom-0 left-0 right-0 p-8">
        <div class="max-w-2xl space-y-4">
          <h1 class="text-4xl font-bold text-text-primary">
            {Map.get(@content, :title) || @content.name}
          </h1>

          <div class="flex items-center gap-4 text-sm text-text-secondary">
            <span :if={Map.get(@content, :year)}>{@content.year}</span>
            <span :if={Map.get(@content, :rating)} class="flex items-center gap-1">
              <.icon name="hero-star-solid" class="size-4 text-yellow-500" />
              {format_rating(@content.rating)}
            </span>
            <span :if={Map.get(@content, :genres, []) != []}>{format_genre_names(@content)}</span>
            <span :if={Map.get(@content, :duration_secs)}>
              {format_duration(@content.duration_secs)}
            </span>
          </div>

          <p :if={Map.get(@content, :plot)} class="text-text-secondary line-clamp-3">
            {@content.plot}
          </p>

          <div class="flex items-center gap-3 pt-2">
            <button
              type="button"
              phx-click={@on_play}
              phx-value-id={@content.id}
              class="inline-flex items-center gap-2 px-6 py-3 bg-brand text-white font-semibold rounded-md hover:bg-brand-hover transition-colors"
            >
              <.icon name="hero-play-solid" class="size-5" /> Assistir
            </button>
            <button
              type="button"
              phx-click={@on_details}
              phx-value-id={@content.id}
              class="inline-flex items-center gap-2 px-6 py-3 bg-surface/60 text-text-primary font-semibold rounded-md hover:bg-surface/80 transition-colors backdrop-blur-sm border border-border"
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
  Renders a "For You" recommendations section with horizontal carousel.

  ## Attributes

    * `:recommendations` - List of recommended movies/series
    * `:on_play` - Event name for play action (default: "play_movie")
    * `:on_details` - Event name for showing details (default: "show_details")

  ## Examples

      <.for_you_section recommendations={@recommendations} />
  """
  attr :recommendations, :list, required: true
  attr :on_play, :string, default: "play_movie"
  attr :on_details, :string, default: "show_details"

  def for_you_section(assigns) do
    ~H"""
    <section class="px-[4%]">
      <div class="flex items-center justify-between mb-3 sm:mb-4">
        <h2 class="flex items-center gap-2 text-base sm:text-xl font-semibold text-text-primary">
          <.icon name="hero-sparkles-solid" class="size-4 sm:size-5 text-yellow-400" /> Para Voce
        </h2>
      </div>

      <%= if @recommendations == [] do %>
        <div class="flex flex-col items-center justify-center py-12 sm:py-16 bg-surface/30 rounded-xl border border-border/50">
          <.icon name="hero-sparkles" class="size-12 sm:size-16 text-text-muted mb-4" />
          <h3 class="text-base sm:text-lg font-medium text-text-secondary mb-2">
            Ainda estamos conhecendo voce
          </h3>
          <p class="text-sm text-text-muted text-center max-w-md px-4">
            Continue assistindo para receber recomendacoes personalizadas baseadas no seu gosto.
          </p>
        </div>
      <% else %>
        <!-- Mobile: 3-column grid showing first 6 items -->
        <div class="grid grid-cols-3 gap-2 sm:hidden">
          <.movie_card
            :for={item <- Enum.take(@recommendations, 6)}
            movie={item}
            show_favorite={false}
            on_play={@on_play}
            on_details={@on_details}
          />
        </div>
        <!-- Desktop: horizontal scrollable carousel -->
        <div class="hidden sm:flex sm:gap-4 sm:overflow-x-auto py-1 sm:py-2 scrollbar-hide scroll-smooth">
          <div :for={item <- @recommendations} class="flex-shrink-0 w-[180px]">
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
