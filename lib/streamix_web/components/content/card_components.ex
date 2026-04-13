defmodule StreamixWeb.Content.CardComponents do
  @moduledoc "Card components"
  use Phoenix.Component
  use StreamixWeb, :verified_routes
  import StreamixWeb.CoreComponents
  import StreamixWeb.AppComponents
  # Shared helpers and internal formats
  import StreamixWeb.Content.HelperComponents
  alias StreamixWeb.Helpers.ImageProxy

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
  attr :show_premium_badge, :boolean, default: false
  attr :progress, :float, default: nil
  attr :on_play, :string, default: "play_movie"
  attr :on_favorite, :string, default: "toggle_favorite"
  attr :on_details, :string, default: "show_details"

  def movie_card(assigns) do
    image_url =
      get_image_url(Map.get(assigns.movie, :stream_icon), Map.get(assigns.movie, :cover))

    rating = get_display_rating(assigns.movie)
    # Safe access for AI recommendations that may not have all fields
    movie_name = Map.get(assigns.movie, :title) || Map.get(assigns.movie, :name, "")
    provider_id = Map.get(assigns.movie, :provider_id)

    assigns =
      assigns
      |> assign(image_url: image_url, display_rating: rating)
      |> assign(movie_name: movie_name, provider_id: provider_id)

    ~H"""
    <div
      id={"movie-card-#{@movie.id}"}
      phx-hook="ContentCard"
      class="group cursor-pointer flex flex-col gap-1 sm:gap-2 transition-all duration-300"
      data-content-id={@movie.id}
      data-content-type="movie"
      data-source-type={@source}
      data-provider-id={@provider_id}
      data-title={@movie_name}
      data-year={Map.get(@movie, :year)}
      data-rating={@display_rating}
      data-plot={Map.get(@movie, :plot)}
      data-cover={ImageProxy.card(Map.get(@movie, :backdrop) || Map.get(@movie, :cover))}
      data-genre={Map.get(@movie, :genre)}
      data-duration={format_duration(Map.get(@movie, :duration))}
      data-favorite={to_string(@is_favorite)}
    >
      <div
        id={"movie-img-fb-#{@movie.id}"}
        class="relative aspect-[2/3] bg-surface-hover overflow-hidden rounded-md sm:rounded-lg shadow-md group-hover:shadow-2xl group-hover:shadow-brand/30 transition-all duration-300 group-hover:-translate-y-1"
        phx-hook="ImageFallback"
        phx-click={@on_details}
        phx-value-id={@movie.id}
        phx-value-provider_id={@provider_id}
      >
        <img
          :if={@image_url}
          src={@image_url}
          alt={@movie_name}
          class="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300 peer"
          loading="lazy"
          data-fallback-target
        />
        <div
          class={[
            "w-full h-full flex flex-col items-center justify-center bg-gradient-to-br from-zinc-800 to-zinc-900 p-3 text-center",
            @image_url && "hidden"
          ]}
          data-fallback
        >
          <.icon name="hero-film" class="size-8 sm:size-12 text-brand/60 mb-2" />
          <span class="text-[10px] sm:text-xs text-text-muted leading-tight line-clamp-3">
            {@movie_name}
          </span>
        </div>

        <div class="absolute inset-0 bg-gradient-to-t from-black/80 via-transparent to-transparent opacity-0 group-hover:opacity-100 transition-opacity" />

        <div class="absolute inset-0 flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity">
          <button
            type="button"
            phx-click={@on_play}
            phx-value-id={@movie.id}
            phx-value-provider_id={@provider_id}
            class="w-10 h-10 sm:w-14 sm:h-14 rounded-full bg-brand/90 backdrop-blur-sm flex items-center justify-center hover:bg-brand hover:scale-110 transition-all shadow-lg"
          >
            <.icon name="hero-play-solid" class="size-5 sm:size-7 text-white ml-0.5" />
          </button>
        </div>

        <div
          :if={@display_rating}
          class="absolute top-1 left-1 sm:top-2 sm:left-2 flex items-center gap-0.5 px-1.5 py-0.5 sm:px-2 sm:py-1 text-[9px] sm:text-xs font-semibold rounded-md bg-black/50 backdrop-blur-md text-yellow-400 shadow-sm"
        >
          <.icon name="hero-star-solid" class="size-2.5 sm:size-3" />
          {@display_rating}
        </div>

        <div
          :if={@show_premium_badge}
          data-premium-badge
          class="absolute top-1 right-1 sm:top-2 sm:right-2"
        >
          <.premium_badge class="shadow-lg bg-black/60 text-white border-white/10" />
        </div>

        <span
          :if={@source == "gindex"}
          class="absolute bottom-1 left-1 sm:bottom-2 sm:left-2 px-1 py-0.5 text-[8px] sm:text-[10px] font-bold rounded bg-purple-600/90 text-white"
        >
          GIndex
        </span>

        <div :if={@progress && @progress > 0} class="absolute bottom-0 left-0 right-0 h-1 bg-zinc-700">
          <div class="h-full bg-brand rounded-r-full" style={"width: #{round(@progress * 100)}%"} />
        </div>
      </div>

      <div class="px-0.5 sm:px-1">
        <div class="flex items-start justify-between gap-1">
          <div class="min-w-0 flex-1 mt-0.5">
            <h3
              class="font-medium text-[11px] sm:text-sm text-text-primary line-clamp-2 leading-tight group-hover:text-brand transition-colors"
              title={@movie_name}
            >
              {@movie_name}
            </h3>
          </div>
          <button
            :if={@show_favorite}
            type="button"
            phx-click={@on_favorite}
            phx-value-id={@movie.id}
            phx-value-type="movie"
            class={[
              "flex-shrink-0 p-1 sm:p-1.5 rounded-full transition-all mt-0.5 focus:opacity-100",
              @is_favorite && "text-red-500 bg-red-500/10 opacity-100",
              !@is_favorite &&
                "text-text-secondary hover:text-red-400 hover:bg-red-500/10 opacity-0 group-hover:opacity-100"
            ]}
          >
            <.icon
              name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"}
              class="size-3.5 sm:size-5"
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
  attr :progress, :float, default: nil
  attr :on_click, :string, default: "view_series"
  attr :on_favorite, :string, default: "toggle_favorite"
  attr :source, :string, default: nil
  attr :show_premium_badge, :boolean, default: false

  def series_card(assigns) do
    rating = get_display_rating(assigns.series)
    assigns = assign(assigns, display_rating: rating)

    ~H"""
    <div
      id={"series-card-#{@series.id}"}
      phx-hook="ContentCard"
      class="group cursor-pointer flex flex-col gap-1 sm:gap-2 transition-all duration-300"
      data-content-id={@series.id}
      data-content-type="series"
      data-source-type={@source}
      data-title={Map.get(@series, :title) || @series.name}
      data-year={Map.get(@series, :year)}
      data-rating={@display_rating}
      data-plot={Map.get(@series, :plot)}
      data-cover={ImageProxy.card(Map.get(@series, :backdrop) || Map.get(@series, :cover))}
      data-genre={Map.get(@series, :genre)}
      data-favorite={to_string(@is_favorite)}
    >
      <div
        id={"series-img-fb-#{@series.id}"}
        class="relative aspect-[2/3] bg-surface-hover overflow-hidden rounded-md sm:rounded-lg shadow-md group-hover:shadow-2xl group-hover:shadow-brand/30 transition-all duration-300 group-hover:-translate-y-1"
        phx-hook="ImageFallback"
        phx-click={@on_click}
        phx-value-id={@series.id}
      >
        <img
          :if={Map.get(@series, :cover)}
          src={ImageProxy.card(@series.cover)}
          alt={@series.name}
          class="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300"
          loading="lazy"
          data-fallback-target
        />
        <div
          class={[
            "w-full h-full flex items-center justify-center bg-gradient-to-br from-zinc-800 to-zinc-900",
            Map.get(@series, :cover) && "hidden"
          ]}
          data-fallback
        >
          <.icon name="hero-video-camera" class="size-8 sm:size-16 text-zinc-600" />
        </div>

        <div
          :if={@display_rating}
          class="absolute top-1 left-1 sm:top-2 sm:left-2 flex items-center gap-0.5 px-1.5 py-0.5 sm:px-2 sm:py-1 text-[9px] sm:text-xs font-semibold rounded-md bg-black/50 backdrop-blur-md text-yellow-400 shadow-sm"
        >
          <.icon name="hero-star-solid" class="size-2.5 sm:size-3" />
          {@display_rating}
        </div>

        <div
          :if={@show_premium_badge}
          data-premium-badge
          class="absolute top-1 right-1 sm:top-2 sm:right-2"
        >
          <.premium_badge class="shadow-lg bg-black/60 text-white border-white/10" />
        </div>

        <span
          :if={@source == "gindex"}
          class="absolute top-1 right-1 sm:top-2 sm:right-2 px-1 py-0.5 text-[8px] sm:text-[10px] font-bold rounded bg-purple-600/90 text-white"
        >
          GDrive
        </span>

        <%!-- episode_count computed from preloaded seasons --%>

        <div :if={@progress && @progress > 0} class="absolute bottom-0 left-0 right-0 h-1 bg-zinc-700">
          <div class="h-full bg-brand rounded-r-full" style={"width: #{round(@progress * 100)}%"} />
        </div>
      </div>

      <div class="px-0.5 sm:px-1">
        <div class="flex items-start justify-between gap-1">
          <div class="min-w-0 flex-1 mt-0.5">
            <h3
              class="font-medium text-[11px] sm:text-sm text-text-primary truncate leading-tight group-hover:text-brand transition-colors"
              title={@series.name}
            >
              {Map.get(@series, :title) || @series.name}
            </h3>
          </div>
          <button
            :if={@show_favorite}
            type="button"
            phx-click={@on_favorite}
            phx-value-id={@series.id}
            phx-value-type="series"
            class={[
              "flex-shrink-0 p-1 sm:p-1.5 rounded-full transition-all mt-0.5 focus:opacity-100",
              @is_favorite && "text-red-500 bg-red-500/10 opacity-100",
              !@is_favorite &&
                "text-text-secondary hover:text-red-400 hover:bg-red-500/10 opacity-0 group-hover:opacity-100"
            ]}
          >
            <.icon
              name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"}
              class={["size-3.5 sm:size-5", @is_favorite && "text-red-500"]}
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
      class="flex gap-3 sm:gap-4 p-2 sm:p-3 rounded-xl cursor-pointer transition-all duration-300 group hover:bg-surface-hover/50 hover:-translate-y-0.5 hover:shadow-lg hover:shadow-brand/5 border border-transparent hover:border-border/40"
      phx-click={@on_play}
      phx-value-id={@episode.id}
    >
      <div
        id={"ep-img-fb-#{@episode.id}"}
        class="relative w-32 sm:w-40 aspect-video flex-shrink-0 bg-surface-hover rounded-lg overflow-hidden shadow-sm group-hover:shadow-md transition-all"
        phx-hook="ImageFallback"
      >
        <img
          :if={Map.get(@episode, :cover)}
          src={ImageProxy.proxy(@episode.cover)}
          alt={episode_title(@episode)}
          class="w-full h-full object-cover"
          loading="lazy"
          data-fallback-target
        />
        <div
          class={[
            "w-full h-full flex items-center justify-center text-text-secondary/30",
            Map.get(@episode, :cover) && "hidden"
          ]}
          data-fallback
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

      <div class="flex-1 min-w-0 py-0.5 sm:py-1">
        <h4 class="font-medium text-sm sm:text-base text-text-primary truncate group-hover:text-brand transition-colors">
          {episode_title(@episode)}
        </h4>
        <p :if={Map.get(@episode, :plot)} class="text-sm text-text-secondary line-clamp-2 mt-1">
          {@episode.plot}
        </p>
        <div class="flex items-center gap-3 mt-2 text-xs text-text-muted">
          <span :if={Map.get(@episode, :duration_secs)}>
            {format_duration(@episode.duration_secs)}
          </span>
          <span :if={Map.get(@episode, :rating)} class="flex items-center gap-1">
            <.icon name="hero-star-solid" class="size-3 text-yellow-500" />
            {format_rating(@episode.rating)}
          </span>
        </div>
      </div>
    </div>
    """
  end
end
