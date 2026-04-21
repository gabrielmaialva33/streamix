defmodule StreamixWeb.Content.CardComponents do
  @moduledoc "Card components — poster 2:3 for movies/series, 16:9 for episodes"
  use Phoenix.Component
  use StreamixWeb, :verified_routes
  import StreamixWeb.CoreComponents
  import StreamixWeb.AppComponents
  import StreamixWeb.Content.HelperComponents
  alias StreamixWeb.Helpers.ImageProxy

  @doc """
  Renders a movie poster card with hover overlay.
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
      class="bg-surface rounded-lg overflow-hidden hover:ring-2 hover:ring-purple-500/50 transition-all cursor-pointer"
      data-content-id={@movie.id}
      data-content-type="movie"
      data-source-type={@source}
      data-provider-id={@provider_id}
      data-title={@movie_name}
      data-year={Map.get(@movie, :year)}
      data-rating={@display_rating}
      data-plot={Map.get(@movie, :plot)}
      data-cover={ImageProxy.poster(Map.get(@movie, :backdrop) || Map.get(@movie, :cover), :carousel)}
      data-genre={Map.get(@movie, :genre)}
      data-duration={format_duration(Map.get(@movie, :duration))}
      data-favorite={to_string(@is_favorite)}
    >
      <%!-- Poster Image --%>
      <div
        id={"movie-img-fb-#{@movie.id}"}
        class="poster-card relative aspect-[2/3] bg-surface-hover overflow-hidden"
        phx-hook="ImageFallback"
        phx-click={@on_details}
        phx-value-id={@movie.id}
        phx-value-provider_id={@provider_id}
      >
        <img
          :if={@image_url}
          src={@image_url}
          alt={@movie_name}
          class="w-full h-full object-cover"
          loading="lazy"
          data-fallback-target
        />
        <div
          class={[
            "w-full h-full flex items-center justify-center bg-gradient-to-br from-purple-900/50 to-gray-900",
            @image_url && "hidden"
          ]}
          data-fallback
        >
          <.icon name="hero-sparkles" class="size-12 sm:size-16 text-purple-400/30" />
        </div>

        <%!-- Premium badge --%>
        <div
          :if={@show_premium_badge}
          data-premium-badge
          class="absolute top-1.5 right-1.5 sm:top-2 sm:right-2"
        >
          <.premium_badge class="shadow-lg bg-black/60 text-white border-white/10" />
        </div>

        <%!-- Source badge --%>
        <span
          :if={@source == "gindex"}
          class="absolute top-2 right-2 px-1.5 py-0.5 text-[10px] font-bold rounded bg-purple-600/90 text-white"
        >
          GDrive
        </span>

        <%!-- Progress bar --%>
        <div :if={@progress && @progress > 0} class="poster-progress">
          <div class="poster-progress-bar" style={"width: #{round(@progress * 100)}%"} />
        </div>
      </div>

      <%!-- Title + year + favorite always visible below poster --%>
      <div class="p-3">
        <div class="flex items-start justify-between gap-2">
          <div class="min-w-0 flex-1">
            <h3 class="font-medium text-sm text-text-primary truncate" title={@movie_name}>
              {@movie_name}
            </h3>
            <p :if={Map.get(@movie, :year)} class="text-xs text-text-secondary">
              {Map.get(@movie, :year)}
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
              class={["size-5", @is_favorite && "text-red-500"]}
            />
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a series poster card with hover overlay.
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
    series_name = Map.get(assigns.series, :title) || Map.get(assigns.series, :name, "")
    assigns = assign(assigns, display_rating: rating, series_name: series_name)

    ~H"""
    <div
      id={"series-card-#{@series.id}"}
      phx-hook="ContentCard"
      class="bg-surface rounded-lg overflow-hidden hover:ring-2 hover:ring-purple-500/50 transition-all cursor-pointer"
      data-content-id={@series.id}
      data-content-type="series"
      data-source-type={@source}
      data-title={@series_name}
      data-year={Map.get(@series, :year)}
      data-rating={@display_rating}
      data-plot={Map.get(@series, :plot)}
      data-cover={ImageProxy.poster(Map.get(@series, :backdrop) || Map.get(@series, :cover), :carousel)}
      data-genre={Map.get(@series, :genre)}
      data-favorite={to_string(@is_favorite)}
    >
      <div
        id={"series-img-fb-#{@series.id}"}
        class="poster-card relative aspect-[2/3] bg-surface-hover overflow-hidden"
        phx-hook="ImageFallback"
        phx-click={@on_click}
        phx-value-id={@series.id}
      >
        <img
          :if={Map.get(@series, :cover)}
          src={ImageProxy.poster(@series.cover, :carousel)}
          alt={@series_name}
          class="w-full h-full object-cover"
          loading="lazy"
          data-fallback-target
        />
        <div
          class={[
            "w-full h-full flex items-center justify-center bg-gradient-to-br from-purple-900/50 to-gray-900",
            Map.get(@series, :cover) && "hidden"
          ]}
          data-fallback
        >
          <.icon name="hero-sparkles" class="size-12 sm:size-16 text-purple-400/30" />
        </div>

        <%!-- Premium badge --%>
        <div
          :if={@show_premium_badge}
          data-premium-badge
          class="absolute top-1.5 right-1.5 sm:top-2 sm:right-2"
        >
          <.premium_badge class="shadow-lg bg-black/60 text-white border-white/10" />
        </div>

        <%!-- Source badge --%>
        <span
          :if={@source == "gindex"}
          class="absolute top-2 right-2 px-1.5 py-0.5 text-[10px] font-bold rounded bg-purple-600/90 text-white"
        >
          GDrive
        </span>

        <%!-- Progress --%>
        <div :if={@progress && @progress > 0} class="poster-progress">
          <div class="poster-progress-bar" style={"width: #{round(@progress * 100)}%"} />
        </div>
      </div>

      <%!-- Title + year + favorite always visible below poster --%>
      <div class="p-3">
        <div class="flex items-start justify-between gap-2">
          <div class="min-w-0 flex-1">
            <h3 class="font-medium text-sm text-text-primary truncate" title={@series_name}>
              {@series_name}
            </h3>
            <p :if={Map.get(@series, :year)} class="text-xs text-text-secondary">
              {Map.get(@series, :year)}
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
  Renders an episode card with thumbnail and metadata.
  """
  attr :episode, :map, required: true
  attr :on_play, :string, default: "play_episode"

  def episode_card(assigns) do
    ~H"""
    <div
      class="flex gap-3 sm:gap-4 p-2.5 sm:p-3 rounded-xl cursor-pointer group hover:bg-surface-elevated/80 border border-transparent hover:border-glass-border transition-all"
      phx-click={@on_play}
      phx-value-id={@episode.id}
    >
      <div
        id={"ep-img-fb-#{@episode.id}"}
        class="relative w-32 sm:w-40 aspect-video flex-shrink-0 bg-surface-hover rounded-lg overflow-hidden"
        phx-hook="ImageFallback"
      >
        <img
          :if={Map.get(@episode, :cover)}
          src={ImageProxy.poster(@episode.cover, :thumbnail)}
          alt={episode_title(@episode)}
          class="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300"
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

        <div class="absolute inset-0 bg-black/50 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <div class="w-10 h-10 rounded-full bg-white/90 flex items-center justify-center">
            <.icon name="hero-play-solid" class="size-5 text-black ml-0.5" />
          </div>
        </div>

        <span class="absolute bottom-1 right-1 px-1.5 py-0.5 text-[10px] font-semibold rounded-md bg-black/70 backdrop-blur-sm text-white">
          E{Map.get(@episode, :episode_num) || Map.get(@episode, :num) || "?"}
        </span>
      </div>

      <div class="flex-1 min-w-0 py-0.5 sm:py-1">
        <h4 class="font-medium text-sm sm:text-base text-text-primary truncate group-hover:text-brand transition-colors">
          {episode_title(@episode)}
        </h4>
        <p
          :if={Map.get(@episode, :plot)}
          class="text-xs sm:text-sm text-text-secondary line-clamp-2 mt-1"
        >
          {@episode.plot}
        </p>
        <div class="flex items-center gap-3 mt-2 text-xs text-text-muted">
          <span :if={Map.get(@episode, :duration_secs)}>
            {format_duration(@episode.duration_secs)}
          </span>
          <span :if={Map.get(@episode, :rating)} class="flex items-center gap-1 text-yellow-500">
            <.icon name="hero-star-solid" class="size-3" />
            {format_rating(@episode.rating)}
          </span>
        </div>
      </div>
    </div>
    """
  end
end
