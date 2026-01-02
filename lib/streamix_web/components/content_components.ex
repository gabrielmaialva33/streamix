defmodule StreamixWeb.ContentComponents do
  @moduledoc """
  Content browsing UI components for Streamix.

  Provides components for:
  - Movie cards with poster and metadata
  - Series cards with episode counts
  - Episode cards/rows
  - Season accordions
  - Content type tabs (Live/Movies/Series)
  - Content carousels and grids
  """
  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import StreamixWeb.CoreComponents

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
        <span :if={@counts[:live]} class="px-1.5 py-0.5 text-[10px] sm:text-xs rounded bg-white/20">
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
        <span :if={@counts[:movies]} class="px-1.5 py-0.5 text-[10px] sm:text-xs rounded bg-white/20">
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
        <span :if={@counts[:series]} class="px-1.5 py-0.5 text-[10px] sm:text-xs rounded bg-white/20">
          {format_count(@counts.series)}
        </span>
      </.link>
    </div>
    """
  end

  @doc """
  Renders navigation tabs for the global browse catalog.

  ## Attributes

    * `:selected` - Currently selected tab (:live, :movies, :series)
    * `:counts` - Map with content counts %{live: n, movies: n, series: n}

  ## Examples

      <.browse_tabs selected={:movies} counts={%{live: 100, movies: 500, series: 50}} />
  """
  attr :selected, :atom, required: true, values: [:live, :movies, :series]
  attr :counts, :map, default: %{}
  attr :source, :string, default: "iptv"

  def browse_tabs(assigns) do
    ~H"""
    <div class="flex bg-surface rounded-lg p-1 gap-1 overflow-x-auto scrollbar-hide">
      <.link
        navigate={browse_path("/browse", @source)}
        class={[
          "flex items-center gap-1.5 sm:gap-2 px-3 sm:px-4 py-1.5 sm:py-2 rounded-md text-xs sm:text-sm font-medium transition-colors whitespace-nowrap flex-shrink-0",
          @selected == :live && "bg-brand text-white",
          @selected != :live && "text-text-secondary hover:text-text-primary hover:bg-surface-hover"
        ]}
      >
        <.icon name="hero-tv" class="size-3.5 sm:size-4" />
        <span>Ao Vivo</span>
        <span :if={@counts[:live]} class="px-1.5 py-0.5 text-[10px] sm:text-xs rounded bg-white/20">
          {format_count(@counts.live)}
        </span>
      </.link>
      <.link
        navigate={browse_path("/browse/movies", @source)}
        class={[
          "flex items-center gap-1.5 sm:gap-2 px-3 sm:px-4 py-1.5 sm:py-2 rounded-md text-xs sm:text-sm font-medium transition-colors whitespace-nowrap flex-shrink-0",
          @selected == :movies && "bg-brand text-white",
          @selected != :movies && "text-text-secondary hover:text-text-primary hover:bg-surface-hover"
        ]}
      >
        <.icon name="hero-film" class="size-3.5 sm:size-4" />
        <span>Filmes</span>
        <span :if={@counts[:movies]} class="px-1.5 py-0.5 text-[10px] sm:text-xs rounded bg-white/20">
          {format_count(@counts.movies)}
        </span>
      </.link>
      <.link
        navigate={browse_path("/browse/series", @source)}
        class={[
          "flex items-center gap-1.5 sm:gap-2 px-3 sm:px-4 py-1.5 sm:py-2 rounded-md text-xs sm:text-sm font-medium transition-colors whitespace-nowrap flex-shrink-0",
          @selected == :series && "bg-brand text-white",
          @selected != :series && "text-text-secondary hover:text-text-primary hover:bg-surface-hover"
        ]}
      >
        <.icon name="hero-video-camera" class="size-3.5 sm:size-4" />
        <span>Séries</span>
        <span :if={@counts[:series]} class="px-1.5 py-0.5 text-[10px] sm:text-xs rounded bg-white/20">
          {format_count(@counts.series)}
        </span>
      </.link>
    </div>
    """
  end

  @doc """
  Renders source tabs for switching between IPTV and GIndex content.

  ## Attributes

    * `:selected` - Currently selected source ("iptv" or "gindex")
    * `:path` - Current path to preserve when switching sources

  ## Examples

      <.source_tabs selected="iptv" path="/browse/movies" />
  """
  attr :selected, :string, required: true
  attr :path, :string, default: "/browse/movies"

  attr :gindex_path, :string,
    default: nil,
    doc: "Override path for GDrive tab (for live which redirects to movies)"

  def source_tabs(assigns) do
    # Use gindex_path if provided, otherwise use the same path
    assigns =
      assign_new(assigns, :gindex_target, fn ->
        if assigns[:gindex_path],
          do: browse_path(assigns.gindex_path, "gindex"),
          else: browse_path(assigns.path, "gindex")
      end)

    ~H"""
    <div class="flex items-center bg-surface rounded-full p-1 gap-0.5">
      <.link
        navigate={browse_path(@path, "iptv")}
        class={[
          "flex items-center gap-1.5 px-4 py-2 rounded-full text-sm font-medium transition-all duration-200 whitespace-nowrap",
          @selected == "iptv" && "bg-brand text-white shadow-sm",
          @selected != "iptv" && "text-text-secondary hover:text-text-primary"
        ]}
      >
        <.icon name="hero-signal" class="size-4" />
        <span>IPTV</span>
      </.link>
      <.link
        navigate={@gindex_target}
        class={[
          "flex items-center gap-1.5 px-4 py-2 rounded-full text-sm font-medium transition-all duration-200 whitespace-nowrap",
          @selected == "gindex" && "bg-brand text-white shadow-sm",
          @selected != "gindex" && "text-text-secondary hover:text-text-primary"
        ]}
      >
        <.icon name="hero-cloud" class="size-4" />
        <span>GDrive</span>
      </.link>
    </div>
    """
  end

  # Helper to build browse paths with source param
  defp browse_path(path, "iptv"), do: path
  defp browse_path(path, source), do: "#{path}?source=#{source}"

  @doc """
  Renders a movie card with poster and metadata.

  ## Attributes

    * `:movie` - The movie struct/map
    * `:is_favorite` - Whether the movie is favorited
    * `:show_favorite` - Whether to show the favorite button
    * `:source` - Content source ("iptv" or "gindex") for badge display
    * `:on_play` - Event name for play action
    * `:on_favorite` - Event name for favorite toggle
    * `:on_details` - Event name for showing details

  ## Examples

      <.movie_card movie={movie} is_favorite={false} />
  """
  attr :movie, :map, required: true
  attr :is_favorite, :boolean, default: false
  attr :show_favorite, :boolean, default: true
  attr :source, :string, default: nil
  attr :on_play, :string, default: "play_movie"
  attr :on_favorite, :string, default: "toggle_favorite"
  attr :on_details, :string, default: "show_details"

  def movie_card(assigns) do
    image_url = get_image_url(assigns.movie.stream_icon, Map.get(assigns.movie, :cover))
    rating = get_display_rating(assigns.movie)
    assigns = assign(assigns, image_url: image_url, display_rating: rating)

    ~H"""
    <div class="bg-surface rounded-lg overflow-hidden hover:ring-2 hover:ring-brand/50 transition-all group cursor-pointer">
      <div
        class="relative aspect-[2/3] bg-surface-hover overflow-hidden"
        phx-click={@on_details}
        phx-value-id={@movie.id}
        phx-value-provider_id={@movie.provider_id}
      >
        <img
          :if={@image_url}
          src={@image_url}
          alt={@movie.name}
          class="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300 peer"
          loading="lazy"
          onerror="this.classList.add('hidden'); this.nextElementSibling?.classList.remove('hidden')"
        />
        <div class={[
          "w-full h-full flex items-center justify-center bg-gradient-to-br from-zinc-800 to-zinc-900",
          @image_url && "hidden"
        ]}>
          <.icon name="hero-film" class="size-16 text-zinc-600" />
        </div>

        <div class="absolute inset-0 bg-gradient-to-t from-black/80 via-transparent to-transparent opacity-0 group-hover:opacity-100 transition-opacity" />

        <div class="absolute inset-0 flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity">
          <button
            type="button"
            phx-click={@on_play}
            phx-value-id={@movie.id}
            phx-value-provider_id={@movie.provider_id}
            class="w-14 h-14 rounded-full bg-brand/90 backdrop-blur-sm flex items-center justify-center hover:bg-brand hover:scale-110 transition-all shadow-lg"
          >
            <.icon name="hero-play-solid" class="size-7 text-white ml-0.5" />
          </button>
        </div>

        <div
          :if={@display_rating}
          class="absolute top-2 left-2 flex items-center gap-1 px-2 py-1 text-xs font-semibold rounded-md bg-black/70 backdrop-blur-sm text-yellow-400"
        >
          <.icon name="hero-star-solid" class="size-3" />
          {@display_rating}
        </div>

        <div
          :if={Map.get(@movie, :year)}
          class="absolute top-2 right-2 px-2 py-1 text-xs font-medium rounded-md bg-black/70 backdrop-blur-sm text-white"
        >
          {@movie.year}
        </div>

        <span
          :if={@source == "gindex"}
          class="absolute bottom-2 left-2 px-1.5 py-0.5 text-[10px] font-bold rounded bg-purple-600/90 text-white"
        >
          GIndex
        </span>
      </div>

      <div class="p-3">
        <div class="flex items-start justify-between gap-2">
          <div class="min-w-0 flex-1">
            <h3
              class="font-medium text-sm text-text-primary line-clamp-2 leading-tight"
              title={@movie.name}
            >
              {Map.get(@movie, :title) || @movie.name}
            </h3>
            <p
              :if={Map.get(@movie, :genre) && @movie.genre != ""}
              class="text-xs text-text-secondary mt-1 truncate"
            >
              {@movie.genre}
            </p>
          </div>
          <button
            :if={@show_favorite}
            type="button"
            phx-click={@on_favorite}
            phx-value-id={@movie.id}
            phx-value-type="movie"
            class={[
              "flex-shrink-0 p-1.5 rounded-full transition-all",
              @is_favorite && "text-red-500 bg-red-500/10",
              !@is_favorite && "text-text-secondary hover:text-red-400 hover:bg-red-500/10"
            ]}
          >
            <.icon
              name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"}
              class="size-5"
            />
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a series card with poster and metadata.

  ## Attributes

    * `:series` - The series struct/map
    * `:is_favorite` - Whether the series is favorited
    * `:show_favorite` - Whether to show the favorite button
    * `:on_click` - Event name for click action
    * `:on_favorite` - Event name for favorite toggle

  ## Examples

      <.series_card series={series} is_favorite={false} />
  """
  attr :series, :map, required: true
  attr :is_favorite, :boolean, default: false
  attr :show_favorite, :boolean, default: true
  attr :on_click, :string, default: "view_series"
  attr :on_favorite, :string, default: "toggle_favorite"
  attr :source, :string, default: nil

  def series_card(assigns) do
    rating = get_display_rating(assigns.series)
    assigns = assign(assigns, display_rating: rating)

    ~H"""
    <div class="bg-surface rounded-lg overflow-hidden hover:ring-2 hover:ring-brand/50 transition-all group cursor-pointer">
      <div
        class="relative aspect-[2/3] bg-surface-hover overflow-hidden"
        phx-click={@on_click}
        phx-value-id={@series.id}
      >
        <img
          :if={Map.get(@series, :cover)}
          src={@series.cover}
          alt={@series.name}
          class="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300"
          loading="lazy"
        />
        <div
          :if={!Map.get(@series, :cover)}
          class="w-full h-full flex items-center justify-center bg-gradient-to-br from-zinc-800 to-zinc-900"
        >
          <.icon name="hero-video-camera" class="size-16 text-zinc-600" />
        </div>

        <div
          :if={@display_rating}
          class="absolute top-2 left-2 flex items-center gap-1 px-2 py-1 text-xs font-semibold rounded-md bg-black/70 backdrop-blur-sm text-yellow-400"
        >
          <.icon name="hero-star-solid" class="size-3" />
          {@display_rating}
        </div>

        <span
          :if={@source == "gindex"}
          class="absolute top-2 right-2 px-1.5 py-0.5 text-[10px] font-bold rounded bg-purple-600/90 text-white"
        >
          GDrive
        </span>

        <div
          :if={Map.get(@series, :episode_count) && @series.episode_count > 0}
          class="absolute bottom-2 left-2 px-2 py-0.5 text-xs rounded bg-brand text-white"
        >
          {@series.episode_count} eps
        </div>
      </div>

      <div class="p-3">
        <div class="flex items-start justify-between gap-2">
          <div class="min-w-0 flex-1">
            <h3 class="font-medium text-sm text-text-primary truncate" title={@series.name}>
              {Map.get(@series, :title) || @series.name}
            </h3>
            <p :if={Map.get(@series, :year)} class="text-xs text-text-secondary">
              {@series.year}
              <span :if={Map.get(@series, :season_count) && @series.season_count > 0}>
                | {pluralize(@series.season_count, "temporada", "temporadas")}
              </span>
            </p>
          </div>
          <button
            :if={@show_favorite}
            type="button"
            phx-click={@on_favorite}
            phx-value-id={@series.id}
            phx-value-type="series"
            class="flex-shrink-0 p-1 hover:scale-110 transition-transform"
          >
            <.icon
              name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"}
              class={["size-5", @is_favorite && "text-red-500"]}
            />
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders an episode card/row for episode lists.

  ## Attributes

    * `:episode` - The episode struct/map
    * `:on_play` - Event name for play action

  ## Examples

      <.episode_card episode={episode} />
  """
  attr :episode, :map, required: true
  attr :on_play, :string, default: "play_episode"

  def episode_card(assigns) do
    ~H"""
    <div
      class="flex gap-4 p-3 bg-surface hover:bg-surface-hover rounded-lg cursor-pointer transition-all group"
      phx-click={@on_play}
      phx-value-id={@episode.id}
    >
      <div class="relative w-40 aspect-video flex-shrink-0 bg-surface-hover rounded overflow-hidden">
        <img
          :if={Map.get(@episode, :cover)}
          src={@episode.cover}
          alt={episode_title(@episode)}
          class="w-full h-full object-cover"
          loading="lazy"
        />
        <div
          :if={!Map.get(@episode, :cover)}
          class="w-full h-full flex items-center justify-center text-text-secondary/30"
        >
          <.icon name="hero-play" class="size-8" />
        </div>

        <div class="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <.icon name="hero-play-solid" class="size-10 text-white" />
        </div>

        <div class="absolute bottom-1 right-1 px-1.5 py-0.5 text-xs rounded bg-black/60 text-white">
          E{Map.get(@episode, :episode_num) || Map.get(@episode, :num) || "?"}
        </div>
      </div>

      <div class="flex-1 min-w-0 py-1">
        <h4 class="font-medium text-text-primary truncate">{episode_title(@episode)}</h4>
        <p :if={Map.get(@episode, :plot)} class="text-sm text-text-secondary line-clamp-2 mt-1">
          {@episode.plot}
        </p>
        <div class="flex items-center gap-3 mt-2 text-xs text-text-muted">
          <span :if={Map.get(@episode, :duration)}>{format_duration(@episode.duration)}</span>
          <span :if={Map.get(@episode, :rating)} class="flex items-center gap-1">
            <.icon name="hero-star-solid" class="size-3 text-yellow-500" />
            {format_rating(@episode.rating)}
          </span>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a season accordion with episodes.

  ## Attributes

    * `:season` - The season struct/map with episodes
    * `:expanded` - Whether the accordion is expanded
    * `:on_toggle` - Event name for toggle action
    * `:on_play_episode` - Event name for episode play

  ## Examples

      <.season_accordion season={season} expanded={false} />
  """
  attr :season, :map, required: true
  attr :expanded, :boolean, default: false
  attr :on_toggle, :string, default: "toggle_season"
  attr :on_play_episode, :string, default: "play_episode"

  def season_accordion(assigns) do
    ~H"""
    <details class="bg-surface rounded-lg group" open={@expanded}>
      <summary
        class="flex items-center justify-between gap-3 px-4 py-3 cursor-pointer hover:bg-surface-hover rounded-lg transition-colors list-none"
        phx-click={@on_toggle}
        phx-value-id={@season.id}
      >
        <div class="flex items-center gap-3">
          <span class="font-medium text-text-primary">
            Temporada {Map.get(@season, :season_number) || Map.get(@season, :num) || "?"}
          </span>
          <span
            :if={Map.get(@season, :episodes)}
            class="px-2 py-0.5 text-xs rounded bg-surface-hover text-text-secondary"
          >
            {length(@season.episodes)} episódios
          </span>
        </div>
        <.icon
          name="hero-chevron-down"
          class="size-5 text-text-secondary transition-transform group-open:rotate-180"
        />
      </summary>
      <div class="px-4 pb-4 space-y-2">
        <.episode_card
          :for={episode <- Map.get(@season, :episodes) || []}
          episode={episode}
          on_play={@on_play_episode}
        />
      </div>
    </details>
    """
  end

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
            <span :if={Map.get(@content, :genre)}>{@content.genre}</span>
            <span :if={Map.get(@content, :duration)}>{format_duration(@content.duration)}</span>
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
              class="inline-flex items-center gap-2 px-6 py-3 bg-white/20 text-white font-semibold rounded-md hover:bg-white/30 transition-colors"
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
  Renders a movie/series detail modal.

  ## Attributes

    * `:content` - The content to display
    * `:type` - Type of content (:movie or :series)
    * `:on_play` - Event name for play action
    * `:on_close` - Event name for closing the modal

  ## Examples

      <.content_detail_modal content={@movie} type={:movie} />
  """
  attr :content, :map, required: true
  attr :type, :atom, required: true, values: [:movie, :series]
  attr :on_play, :string, default: "play"
  attr :on_close, :string, default: "close_detail"

  def content_detail_modal(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80"
      phx-click-away={@on_close}
    >
      <div class="bg-surface rounded-lg overflow-hidden max-w-3xl w-full shadow-2xl">
        <div class="relative h-64 bg-surface-hover">
          <img
            :if={Map.get(@content, :backdrop) || Map.get(@content, :cover)}
            src={Map.get(@content, :backdrop) || Map.get(@content, :cover)}
            alt={@content.name}
            class="w-full h-full object-cover"
          />
          <div class="absolute inset-0 bg-gradient-to-t from-surface to-transparent" />

          <button
            type="button"
            phx-click={@on_close}
            class="absolute top-4 right-4 p-2 rounded-full bg-black/50 text-white hover:bg-black/70 transition-colors"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>

          <div class="absolute bottom-4 left-6 right-6">
            <h2 class="text-2xl font-bold text-white">
              {Map.get(@content, :title) || @content.name}
            </h2>
          </div>
        </div>

        <div class="p-6 space-y-4">
          <div class="flex items-center gap-4 text-sm text-text-secondary">
            <span :if={Map.get(@content, :year)}>{@content.year}</span>
            <span :if={Map.get(@content, :rating)} class="flex items-center gap-1">
              <.icon name="hero-star-solid" class="size-4 text-yellow-500" />
              {format_rating(@content.rating)}
            </span>
            <span :if={Map.get(@content, :genre)}>{@content.genre}</span>
            <span :if={Map.get(@content, :duration)}>{format_duration(@content.duration)}</span>
          </div>

          <p :if={Map.get(@content, :plot)} class="text-text-secondary">
            {@content.plot}
          </p>

          <div class="flex items-center gap-3 pt-4">
            <button
              type="button"
              phx-click={@on_play}
              phx-value-id={@content.id}
              class="inline-flex items-center gap-2 px-6 py-3 bg-brand text-white font-semibold rounded-md hover:bg-brand-hover transition-colors"
            >
              <.icon name="hero-play-solid" class="size-5" /> Assistir
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp format_count(count) when count >= 1000 do
    "#{Float.round(count / 1000, 1)}k"
  end

  defp format_count(count), do: to_string(count)

  defp format_rating(%Decimal{} = rating) do
    rating
    |> Decimal.div(2)
    |> Decimal.round(1)
    |> Decimal.to_string()
  end

  defp format_rating(rating) when is_number(rating) do
    Float.round(rating / 2, 1) |> to_string()
  end

  defp format_rating(_), do: nil

  defp format_duration(duration) when is_binary(duration), do: duration

  defp format_duration(duration) when is_integer(duration) do
    hours = div(duration, 60)
    minutes = rem(duration, 60)

    if hours > 0, do: "#{hours}h #{minutes}min", else: "#{minutes}min"
  end

  defp format_duration(_), do: nil

  defp episode_title(episode) do
    Map.get(episode, :title) ||
      "Episódio #{Map.get(episode, :episode_num) || Map.get(episode, :num) || "?"}"
  end

  defp pluralize(1, singular, _plural), do: "1 #{singular}"
  defp pluralize(count, _singular, plural), do: "#{count} #{plural}"

  # Returns a valid image URL or nil
  defp get_image_url(stream_icon, cover) do
    cond do
      is_binary(stream_icon) and stream_icon != "" -> stream_icon
      is_binary(cover) and cover != "" -> cover
      true -> nil
    end
  end

  # Returns display rating string or nil (hides 0 ratings)
  defp get_display_rating(item) do
    rating = Map.get(item, :rating)

    case rating do
      nil ->
        nil

      %Decimal{} = d ->
        if Decimal.compare(d, Decimal.new("0")) == :gt do
          d |> Decimal.div(2) |> Decimal.round(1) |> Decimal.to_string()
        else
          nil
        end

      n when is_number(n) and n > 0 ->
        Float.round(n / 2, 1) |> to_string()

      _ ->
        nil
    end
  end
end
