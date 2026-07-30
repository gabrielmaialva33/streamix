defmodule StreamixWeb.Content.CardComponents do
  @moduledoc "Card components — poster 2:3 for movies/series, 16:9 for episodes"
  use Phoenix.Component
  use StreamixWeb, :verified_routes
  import StreamixWeb.CoreComponents
  import StreamixWeb.App.Premium
  import StreamixWeb.Content.HelperComponents
  alias StreamixWeb.Helpers.ImageProxy

  attr :id, :string, required: true
  attr :image_id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :any, default: nil
  attr :image_url, :string, default: nil
  attr :fallback_icon, :string, default: "hero-film"
  attr :content_id, :any, required: true
  attr :content_type, :string, required: true
  attr :provider_id, :any, default: nil
  attr :navigate, :string, default: nil
  attr :on_click, :string, default: nil
  attr :progress, :any, default: nil
  attr :image_fit, :string, values: ~w(cover contain), default: "cover"
  attr :class, :any, default: nil
  attr :rest, :global

  slot :badge
  slot :secondary_action
  slot :metadata

  @doc "Renders a semantic 2:3 poster card with sibling secondary actions."
  def poster_media_card(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "content-card group/card relative overflow-hidden rounded-lg bg-surface transition-all hover:ring-2 hover:ring-brand/50",
        @class
      ]}
      {@rest}
    >
      <.media_primary_action
        navigate={@navigate}
        on_click={@on_click}
        content_id={@content_id}
        content_type={@content_type}
        provider_id={@provider_id}
        title={@title}
        class="block w-full cursor-pointer text-left focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand"
      >
        <div
          id={@image_id}
          class="poster-card relative aspect-[2/3] overflow-hidden bg-surface-hover"
          phx-hook="ImageFallback"
        >
          <img
            :if={@image_url}
            src={@image_url}
            alt={@title}
            class={[
              "h-full w-full transition-transform duration-300 group-hover/card:scale-[1.02]",
              @image_fit == "cover" && "object-cover",
              @image_fit == "contain" && "object-contain"
            ]}
            loading="lazy"
            decoding="async"
            data-fallback-target
          />
          <div
            class={[
              "flex h-full w-full items-center justify-center bg-surface-hover",
              @image_url && "hidden"
            ]}
            data-fallback
          >
            <.icon name={@fallback_icon} class="size-12 text-text-secondary/30 sm:size-16" />
          </div>

          <div
            :if={@badge != []}
            class="absolute right-1.5 top-1.5 flex flex-col items-end gap-1 sm:right-2 sm:top-2"
          >
            <%= for badge <- @badge do %>
              {render_slot(badge)}
            <% end %>
          </div>

          <div :if={progress_percent(@progress)} class="poster-progress">
            <div class="poster-progress-bar" style={"width: #{progress_percent(@progress)}%"} />
          </div>
        </div>

        <div class={["p-3", @secondary_action != [] && "pr-14"]}>
          <h3 class="truncate text-sm font-medium text-text-primary" title={@title}>
            {@title}
          </h3>
          <p :if={@subtitle not in [nil, ""]} class="min-h-4 text-xs text-text-secondary">
            {@subtitle}
          </p>
          <%= for metadata <- @metadata do %>
            {render_slot(metadata)}
          <% end %>
        </div>
      </.media_primary_action>

      <div
        :if={@secondary_action != []}
        data-media-secondary
        class="absolute bottom-2 right-2 z-10"
      >
        <%= for action <- @secondary_action do %>
          {render_slot(action)}
        <% end %>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :image_id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :any, default: nil
  attr :image_url, :string, default: nil
  attr :fallback_icon, :string, default: "hero-play"
  attr :content_id, :any, required: true
  attr :content_type, :string, required: true
  attr :provider_id, :any, default: nil
  attr :navigate, :string, default: nil
  attr :on_click, :string, default: nil
  attr :progress, :any, default: nil
  attr :image_fit, :string, values: ~w(cover contain), default: "cover"
  attr :layout, :atom, values: [:stacked, :row], default: :stacked
  attr :class, :any, default: nil
  attr :rest, :global

  slot :badge
  slot :secondary_action
  slot :metadata

  @doc "Renders a semantic 16:9 media card for live, episode, and history surfaces."
  def landscape_media_card(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "content-card group/card relative overflow-hidden rounded-xl bg-surface transition-all hover:ring-2 hover:ring-brand/50",
        @class
      ]}
      {@rest}
    >
      <.media_primary_action
        navigate={@navigate}
        on_click={@on_click}
        content_id={@content_id}
        content_type={@content_type}
        provider_id={@provider_id}
        title={@title}
        class={[
          "w-full cursor-pointer text-left focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand",
          @layout == :stacked && "block",
          @layout == :row && "flex items-start gap-3 p-2.5 sm:gap-4 sm:p-3"
        ]}
      >
        <div
          id={@image_id}
          class={[
            "relative aspect-video flex-shrink-0 overflow-hidden bg-surface-hover",
            @layout == :stacked && "w-full",
            @layout == :row && "w-32 rounded-lg sm:w-40"
          ]}
          phx-hook="ImageFallback"
        >
          <img
            :if={@image_url}
            src={@image_url}
            alt={@title}
            class={[
              "h-full w-full transition-transform duration-300 group-hover/card:scale-[1.03]",
              @image_fit == "cover" && "object-cover",
              @image_fit == "contain" && "object-contain"
            ]}
            loading="lazy"
            decoding="async"
            data-fallback-target
          />
          <div
            class={[
              "flex h-full w-full items-center justify-center bg-surface-hover text-text-secondary/30",
              @image_url && "hidden"
            ]}
            data-fallback
          >
            <.icon name={@fallback_icon} class="size-8 sm:size-10" />
          </div>

          <div class="absolute inset-0 hidden items-center justify-center bg-black/35 group-hover/card:flex">
            <span class="flex size-10 items-center justify-center rounded-full bg-white/90">
              <.icon name="hero-play-solid" class="ml-0.5 size-5 text-black" />
            </span>
          </div>

          <div :if={@badge != []} class="absolute bottom-1 right-1 flex flex-col items-end gap-1">
            <%= for badge <- @badge do %>
              {render_slot(badge)}
            <% end %>
          </div>

          <div :if={progress_percent(@progress)} class="poster-progress">
            <div class="poster-progress-bar" style={"width: #{progress_percent(@progress)}%"} />
          </div>
        </div>

        <div class={[
          "min-w-0 flex-1",
          @layout == :stacked && "p-3",
          @layout == :row && "py-0.5 sm:py-1",
          @secondary_action != [] && "pr-12"
        ]}>
          <h3
            class="truncate text-sm font-medium text-text-primary transition-colors group-hover/card:text-brand sm:text-base"
            title={@title}
          >
            {@title}
          </h3>
          <p
            :if={@subtitle not in [nil, ""]}
            class="mt-1 line-clamp-2 text-xs text-text-secondary sm:text-sm"
          >
            {@subtitle}
          </p>
          <%= for metadata <- @metadata do %>
            {render_slot(metadata)}
          <% end %>
        </div>
      </.media_primary_action>

      <div
        :if={@secondary_action != []}
        data-media-secondary
        class="absolute bottom-2 right-2 z-10"
      >
        <%= for action <- @secondary_action do %>
          {render_slot(action)}
        <% end %>
      </div>
    </div>
    """
  end

  attr :navigate, :string, default: nil
  attr :on_click, :string, default: nil
  attr :content_id, :any, required: true
  attr :content_type, :string, required: true
  attr :provider_id, :any, default: nil
  attr :title, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block, required: true

  defp media_primary_action(%{navigate: navigate} = assigns)
       when is_binary(navigate) and navigate != "" do
    ~H"""
    <.link
      navigate={@navigate}
      data-media-primary
      data-content-id={@content_id}
      data-content-type={@content_type}
      aria-label={"Abrir #{@title}"}
      class={@class}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp media_primary_action(assigns) do
    ~H"""
    <button
      type="button"
      data-media-primary
      data-content-id={@content_id}
      data-content-type={@content_type}
      phx-click={@on_click}
      phx-value-id={@content_id}
      phx-value-type={@content_type}
      phx-value-provider_id={@provider_id}
      aria-label={"Abrir #{@title}"}
      class={@class}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

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
    <.poster_media_card
      id={"movie-card-#{@movie.id}"}
      image_id={"movie-img-fb-#{@movie.id}"}
      title={@movie_name}
      subtitle={display_year(Map.get(@movie, :year))}
      image_url={@image_url}
      fallback_icon="hero-film"
      content_id={@movie.id}
      content_type="movie"
      provider_id={@provider_id}
      on_click={@on_details}
      progress={@progress}
      phx-hook="ContentCard"
      data-content-id={@movie.id}
      data-content-type="movie"
      data-source-type={@source}
      data-provider-id={@provider_id}
      data-title={@movie_name}
      data-year={Map.get(@movie, :year)}
      data-rating={@display_rating}
      data-plot={preview_plot(@movie)}
      data-cover={
        ImageProxy.browser_poster(
          Map.get(@movie, :backdrop) || Map.get(@movie, :cover),
          :carousel
        )
      }
      data-genre={Map.get(@movie, :genre)}
      data-duration={format_duration(Map.get(@movie, :duration))}
      data-favorite={to_string(@is_favorite)}
    >
      <:badge :if={@show_premium_badge}>
        <div data-premium-badge>
          <.premium_badge class="border-white/10 bg-black/60 text-white shadow-lg" />
        </div>
      </:badge>
      <:badge :if={@source == "gindex"}>
        <span class="rounded bg-info/90 px-1.5 py-0.5 text-[10px] font-bold text-white">
          GDrive
        </span>
      </:badge>
      <:secondary_action :if={@show_favorite}>
        <button
          type="button"
          phx-click={@on_favorite}
          phx-value-id={@movie.id}
          phx-value-type="movie"
          class="flex size-11 flex-shrink-0 items-center justify-center rounded-md text-text-secondary transition-all hover:scale-105 hover:bg-brand/10 hover:text-brand focus:outline-none focus:ring-2 focus:ring-brand"
          aria-label={if @is_favorite, do: "Remover dos favoritos", else: "Adicionar aos favoritos"}
        >
          <.icon
            name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"}
            class={["size-5", @is_favorite && "text-brand"]}
          />
        </button>
      </:secondary_action>
    </.poster_media_card>
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
    image_url = ImageProxy.browser_poster(Map.get(assigns.series, :cover), :carousel)

    provider_id = Map.get(assigns.series, :provider_id)

    assigns =
      assign(assigns,
        display_rating: rating,
        series_name: series_name,
        image_url: image_url,
        provider_id: provider_id
      )

    ~H"""
    <.poster_media_card
      id={"series-card-#{@series.id}"}
      image_id={"series-img-fb-#{@series.id}"}
      title={@series_name}
      subtitle={display_year(Map.get(@series, :year))}
      image_url={@image_url}
      fallback_icon="hero-tv"
      content_id={@series.id}
      content_type="series"
      provider_id={@provider_id}
      on_click={@on_click}
      progress={@progress}
      phx-hook="ContentCard"
      data-content-id={@series.id}
      data-content-type="series"
      data-source-type={@source}
      data-provider-id={@provider_id}
      data-title={@series_name}
      data-year={Map.get(@series, :year)}
      data-rating={@display_rating}
      data-plot={preview_plot(@series)}
      data-cover={
        ImageProxy.browser_poster(
          Map.get(@series, :backdrop) || Map.get(@series, :cover),
          :carousel
        )
      }
      data-genre={Map.get(@series, :genre)}
      data-favorite={to_string(@is_favorite)}
    >
      <:badge :if={@show_premium_badge}>
        <div data-premium-badge>
          <.premium_badge class="border-white/10 bg-black/60 text-white shadow-lg" />
        </div>
      </:badge>
      <:badge :if={@source == "gindex"}>
        <span class="rounded bg-info/90 px-1.5 py-0.5 text-[10px] font-bold text-white">
          GDrive
        </span>
      </:badge>
      <:secondary_action :if={@show_favorite}>
        <button
          type="button"
          phx-click={@on_favorite}
          phx-value-id={@series.id}
          phx-value-type="series"
          class="flex size-11 flex-shrink-0 items-center justify-center rounded-md text-text-secondary transition-all hover:scale-105 hover:bg-brand/10 hover:text-brand focus:outline-none focus:ring-2 focus:ring-brand"
          aria-label={if @is_favorite, do: "Remover dos favoritos", else: "Adicionar aos favoritos"}
        >
          <.icon
            name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"}
            class={["size-5", @is_favorite && "text-brand"]}
          />
        </button>
      </:secondary_action>
    </.poster_media_card>
    """
  end

  @doc """
  Renders an episode card with thumbnail and metadata.
  """
  attr :episode, :map, required: true
  attr :on_play, :string, default: "play_episode"

  def episode_card(assigns) do
    image_url =
      case Map.get(assigns.episode, :cover) do
        cover when is_binary(cover) and cover != "" -> ImageProxy.poster(cover, :thumbnail)
        _other -> nil
      end

    assigns =
      assigns
      |> assign(:image_url, image_url)
      |> assign(
        :episode_number,
        Map.get(assigns.episode, :episode_num) || Map.get(assigns.episode, :num) || "?"
      )

    ~H"""
    <.landscape_media_card
      id={"episode-card-#{@episode.id}"}
      image_id={"ep-img-fb-#{@episode.id}"}
      title={episode_title(@episode)}
      subtitle={Map.get(@episode, :plot)}
      image_url={@image_url}
      fallback_icon="hero-play"
      content_id={@episode.id}
      content_type="episode"
      on_click={@on_play}
      layout={:row}
      class="border border-transparent bg-transparent hover:border-glass-border hover:bg-surface-elevated/80"
    >
      <:badge>
        <span class="rounded-md bg-black/70 px-1.5 py-0.5 text-[10px] font-semibold text-white backdrop-blur-sm">
          E{@episode_number}
        </span>
      </:badge>
      <:metadata>
        <div class="mt-2 flex items-center gap-3 text-xs text-text-muted">
          <span :if={Map.get(@episode, :duration_secs)}>
            {format_duration(@episode.duration_secs)}
          </span>
          <span :if={Map.get(@episode, :rating)} class="flex items-center gap-1 text-warning">
            <.icon name="hero-star-solid" class="size-3" />
            {format_rating(@episode.rating)}
          </span>
        </div>
      </:metadata>
    </.landscape_media_card>
    """
  end

  defp progress_percent(progress) when is_number(progress) and progress > 0 do
    progress
    |> Kernel.*(100)
    |> round()
    |> min(100)
  end

  defp progress_percent(_progress), do: nil

  defp preview_plot(item) do
    case Map.get(item, :plot) do
      plot when is_binary(plot) -> String.slice(plot, 0, 240)
      _other -> nil
    end
  end
end
