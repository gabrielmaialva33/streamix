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
    <div class="tabs tabs-boxed bg-base-200 p-1 inline-flex">
      <.link
        navigate={~p"/providers/#{@provider_id}"}
        class={["tab gap-2", @selected == :live && "tab-active"]}
      >
        <.icon name="hero-tv" class="size-4" />
        <span>Ao Vivo</span>
        <span :if={@counts[:live]} class="badge badge-sm badge-ghost">
          {format_count(@counts.live)}
        </span>
      </.link>
      <.link
        navigate={~p"/providers/#{@provider_id}/movies"}
        class={["tab gap-2", @selected == :movies && "tab-active"]}
      >
        <.icon name="hero-film" class="size-4" />
        <span>Filmes</span>
        <span :if={@counts[:movies]} class="badge badge-sm badge-ghost">
          {format_count(@counts.movies)}
        </span>
      </.link>
      <.link
        navigate={~p"/providers/#{@provider_id}/series"}
        class={["tab gap-2", @selected == :series && "tab-active"]}
      >
        <.icon name="hero-video-camera" class="size-4" />
        <span>Séries</span>
        <span :if={@counts[:series]} class="badge badge-sm badge-ghost">
          {format_count(@counts.series)}
        </span>
      </.link>
    </div>
    """
  end

  @doc """
  Renders a movie card with poster and metadata.

  ## Attributes

    * `:movie` - The movie struct/map
    * `:is_favorite` - Whether the movie is favorited
    * `:show_favorite` - Whether to show the favorite button
    * `:on_play` - Event name for play action
    * `:on_favorite` - Event name for favorite toggle
    * `:on_details` - Event name for showing details

  ## Examples

      <.movie_card movie={movie} is_favorite={false} />
  """
  attr :movie, :map, required: true
  attr :is_favorite, :boolean, default: false
  attr :show_favorite, :boolean, default: true
  attr :on_play, :string, default: "play_movie"
  attr :on_favorite, :string, default: "toggle_favorite"
  attr :on_details, :string, default: "show_details"

  def movie_card(assigns) do
    ~H"""
    <div class="card bg-base-200 hover:bg-base-300 transition-all group cursor-pointer">
      <figure
        class="relative aspect-[2/3] bg-base-300"
        phx-click={@on_details}
        phx-value-id={@movie.id}
      >
        <img
          :if={@movie.stream_icon || @movie[:cover]}
          src={@movie.stream_icon || @movie[:cover]}
          alt={@movie.name}
          class="w-full h-full object-cover"
          loading="lazy"
        />
        <div
          :if={!@movie.stream_icon && !@movie[:cover]}
          class="w-full h-full flex items-center justify-center text-base-content/30"
        >
          <.icon name="hero-film" class="size-16" />
        </div>

        <div class="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <button
            type="button"
            phx-click={@on_play}
            phx-value-id={@movie.id}
            class="btn btn-circle btn-lg btn-primary"
          >
            <.icon name="hero-play-solid" class="size-8" />
          </button>
        </div>

        <div :if={@movie[:rating]} class="absolute top-2 left-2 badge badge-sm badge-warning gap-1">
          <.icon name="hero-star-solid" class="size-3" />
          {format_rating(@movie.rating)}
        </div>

        <div :if={@movie[:year]} class="absolute top-2 right-2 badge badge-sm badge-ghost">
          {@movie.year}
        </div>
      </figure>

      <div class="card-body p-3">
        <div class="flex items-start justify-between gap-2">
          <div class="min-w-0 flex-1">
            <h3 class="font-medium text-sm truncate" title={@movie.name}>
              {@movie[:title] || @movie.name}
            </h3>
            <p :if={@movie[:genre]} class="text-xs text-base-content/60 truncate">
              {@movie.genre}
            </p>
            <p :if={@movie[:duration]} class="text-xs text-base-content/50">
              {format_duration(@movie.duration)}
            </p>
          </div>
          <button
            :if={@show_favorite}
            type="button"
            phx-click={@on_favorite}
            phx-value-id={@movie.id}
            phx-value-type="movie"
            class="flex-shrink-0 p-1 hover:scale-110 transition-transform"
          >
            <.icon
              name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"}
              class={["size-5", @is_favorite && "text-error"]}
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

  def series_card(assigns) do
    ~H"""
    <div class="card bg-base-200 hover:bg-base-300 transition-all group cursor-pointer">
      <figure
        class="relative aspect-[2/3] bg-base-300"
        phx-click={@on_click}
        phx-value-id={@series.id}
      >
        <img
          :if={@series[:cover]}
          src={@series.cover}
          alt={@series.name}
          class="w-full h-full object-cover"
          loading="lazy"
        />
        <div
          :if={!@series[:cover]}
          class="w-full h-full flex items-center justify-center text-base-content/30"
        >
          <.icon name="hero-video-camera" class="size-16" />
        </div>

        <div :if={@series[:rating]} class="absolute top-2 left-2 badge badge-sm badge-warning gap-1">
          <.icon name="hero-star-solid" class="size-3" />
          {format_rating(@series.rating)}
        </div>

        <div
          :if={@series[:episode_count] && @series.episode_count > 0}
          class="absolute bottom-2 left-2 badge badge-sm badge-primary"
        >
          {@series.episode_count} eps
        </div>
      </figure>

      <div class="card-body p-3">
        <div class="flex items-start justify-between gap-2">
          <div class="min-w-0 flex-1">
            <h3 class="font-medium text-sm truncate" title={@series.name}>
              {@series[:title] || @series.name}
            </h3>
            <p :if={@series[:year]} class="text-xs text-base-content/60">
              {@series.year}
              <span :if={@series[:season_count] && @series.season_count > 0}>
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
              class={["size-5", @is_favorite && "text-error"]}
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
      class="flex gap-4 p-3 bg-base-200 hover:bg-base-300 rounded-lg cursor-pointer transition-all group"
      phx-click={@on_play}
      phx-value-id={@episode.id}
    >
      <div class="relative w-40 aspect-video flex-shrink-0 bg-base-300 rounded overflow-hidden">
        <img
          :if={@episode[:cover]}
          src={@episode.cover}
          alt={episode_title(@episode)}
          class="w-full h-full object-cover"
          loading="lazy"
        />
        <div
          :if={!@episode[:cover]}
          class="w-full h-full flex items-center justify-center text-base-content/30"
        >
          <.icon name="hero-play" class="size-8" />
        </div>

        <div class="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <.icon name="hero-play-solid" class="size-10 text-white" />
        </div>

        <div class="absolute bottom-1 right-1 badge badge-sm badge-ghost">
          E{@episode[:episode_num] || @episode[:num] || "?"}
        </div>
      </div>

      <div class="flex-1 min-w-0 py-1">
        <h4 class="font-medium truncate">{episode_title(@episode)}</h4>
        <p :if={@episode[:plot]} class="text-sm text-base-content/60 line-clamp-2 mt-1">
          {@episode.plot}
        </p>
        <div class="flex items-center gap-3 mt-2 text-xs text-base-content/50">
          <span :if={@episode[:duration]}>{format_duration(@episode.duration)}</span>
          <span :if={@episode[:rating]} class="flex items-center gap-1">
            <.icon name="hero-star-solid" class="size-3 text-warning" />
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
    <div class="collapse collapse-arrow bg-base-200 rounded-lg">
      <input
        type="checkbox"
        checked={@expanded}
        phx-click={@on_toggle}
        phx-value-id={@season.id}
      />
      <div class="collapse-title font-medium flex items-center gap-3">
        <span>Temporada {@season[:season_number] || @season[:num] || "?"}</span>
        <span :if={@season[:episodes]} class="badge badge-sm badge-ghost">
          {length(@season.episodes)} episódios
        </span>
      </div>
      <div class="collapse-content">
        <div class="space-y-2 pt-2">
          <.episode_card
            :for={episode <- @season[:episodes] || []}
            episode={episode}
            on_play={@on_play_episode}
          />
        </div>
      </div>
    </div>
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
        <h2 class="text-xl font-bold">{@title}</h2>
        <.link :if={@see_all_path} navigate={@see_all_path} class="btn btn-ghost btn-sm">
          Ver tudo <.icon name="hero-arrow-right" class="size-4" />
        </.link>
      </div>

      <div class="flex gap-4 overflow-x-auto pb-4 scrollbar-thin scrollbar-thumb-base-300">
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
    <div class="relative h-[50vh] min-h-[400px] bg-base-300 rounded-xl overflow-hidden">
      <img
        :if={@content[:backdrop] || @content[:cover]}
        src={@content[:backdrop] || @content[:cover]}
        alt={@content.name}
        class="w-full h-full object-cover"
      />
      <div class="absolute inset-0 bg-gradient-to-t from-base-100 via-base-100/50 to-transparent" />

      <div class="absolute bottom-0 left-0 right-0 p-8">
        <div class="max-w-2xl space-y-4">
          <h1 class="text-4xl font-bold">{@content[:title] || @content.name}</h1>

          <div class="flex items-center gap-4 text-sm text-base-content/70">
            <span :if={@content[:year]}>{@content.year}</span>
            <span :if={@content[:rating]} class="flex items-center gap-1">
              <.icon name="hero-star-solid" class="size-4 text-warning" />
              {format_rating(@content.rating)}
            </span>
            <span :if={@content[:genre]}>{@content.genre}</span>
            <span :if={@content[:duration]}>{format_duration(@content.duration)}</span>
          </div>

          <p :if={@content[:plot]} class="text-base-content/80 line-clamp-3">
            {@content.plot}
          </p>

          <div class="flex items-center gap-3 pt-2">
            <button
              type="button"
              phx-click={@on_play}
              phx-value-id={@content.id}
              class="btn btn-primary gap-2"
            >
              <.icon name="hero-play-solid" class="size-5" /> Assistir
            </button>
            <button
              type="button"
              phx-click={@on_details}
              phx-value-id={@content.id}
              class="btn btn-ghost gap-2"
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
    <div class="modal modal-open" phx-click-away={@on_close}>
      <div class="modal-box max-w-3xl p-0">
        <div class="relative h-64 bg-base-300">
          <img
            :if={@content[:backdrop] || @content[:cover]}
            src={@content[:backdrop] || @content[:cover]}
            alt={@content.name}
            class="w-full h-full object-cover"
          />
          <div class="absolute inset-0 bg-gradient-to-t from-base-100 to-transparent" />

          <button
            type="button"
            phx-click={@on_close}
            class="btn btn-circle btn-ghost btn-sm absolute top-4 right-4 text-white"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>

          <div class="absolute bottom-4 left-6 right-6">
            <h2 class="text-2xl font-bold text-white">{@content[:title] || @content.name}</h2>
          </div>
        </div>

        <div class="p-6 space-y-4">
          <div class="flex items-center gap-4 text-sm text-base-content/70">
            <span :if={@content[:year]}>{@content.year}</span>
            <span :if={@content[:rating]} class="flex items-center gap-1">
              <.icon name="hero-star-solid" class="size-4 text-warning" />
              {format_rating(@content.rating)}
            </span>
            <span :if={@content[:genre]}>{@content.genre}</span>
            <span :if={@content[:duration]}>{format_duration(@content.duration)}</span>
          </div>

          <p :if={@content[:plot]} class="text-base-content/80">
            {@content.plot}
          </p>

          <div class="flex items-center gap-3 pt-4">
            <button
              type="button"
              phx-click={@on_play}
              phx-value-id={@content.id}
              class="btn btn-primary gap-2"
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
    episode[:title] || "Episódio #{episode[:episode_num] || episode[:num] || "?"}"
  end

  defp pluralize(1, singular, _plural), do: "1 #{singular}"
  defp pluralize(count, _singular, plural), do: "#{count} #{plural}"
end
