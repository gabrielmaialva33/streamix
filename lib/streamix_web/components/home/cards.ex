defmodule StreamixWeb.Home.Cards do
  @moduledoc """
  Card components used by the home carousels.
  """

  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import StreamixWeb.Content.CardComponents
  import StreamixWeb.CoreComponents
  import StreamixWeb.Home.Helpers

  alias StreamixWeb.Helpers.ImageProxy

  def render_movie_card(assigns) do
    assigns =
      assigns
      |> assign_new(:class, fn -> nil end)
      |> assign_new(:progress, fn -> nil end)
      |> assign_new(:is_favorite, fn -> false end)

    ~H"""
    <div class={[
      "w-[30vw] min-w-[104px] max-w-[122px] flex-shrink-0 snap-start sm:w-[132px] sm:max-w-none lg:w-[148px]",
      @class
    ]}>
      <.movie_card
        movie={@movie}
        is_favorite={@is_favorite}
        progress={@progress}
        show_favorite={false}
        on_play="play_movie"
        on_details="play_movie"
      />
    </div>
    """
  end

  def render_series_card(assigns) do
    assigns =
      assigns
      |> assign_new(:class, fn -> nil end)
      |> assign_new(:progress, fn -> nil end)
      |> assign_new(:is_favorite, fn -> false end)

    ~H"""
    <div class={[
      "w-[30vw] min-w-[104px] max-w-[122px] flex-shrink-0 snap-start sm:w-[132px] sm:max-w-none lg:w-[148px]",
      @class
    ]}>
      <.series_card
        series={@series}
        is_favorite={@is_favorite}
        progress={@progress}
        show_favorite={false}
        on_click="view_series"
      />
    </div>
    """
  end

  def channel_card(assigns) do
    assigns =
      assigns
      |> assign_new(:class, fn -> nil end)
      |> assign(:image_url, ImageProxy.browser_image(assigns.channel.stream_icon))

    ~H"""
    <.link
      href={~p"/watch/live_channel/#{@channel.id}"}
      class={[
        "content-card group block w-[42vw] min-w-[148px] max-w-[180px] flex-shrink-0 snap-start transition-all duration-300 sm:w-[150px] sm:max-w-none lg:w-[176px]",
        @class
      ]}
    >
      <div class="relative flex aspect-video items-center justify-center overflow-hidden rounded-md bg-surface-hover shadow-sm transition-all duration-300 group-hover:-translate-y-1 group-hover:shadow-xl group-hover:shadow-brand/20 sm:rounded-lg">
        <div id={"home-ch-img-#{@channel.id}"} phx-hook="ImageFallback" class="w-full h-full">
          <img
            :if={@image_url}
            src={@image_url}
            alt={@channel.name}
            class="w-full h-full object-contain p-1.5 sm:p-2 animate-fade-in"
            loading="lazy"
            decoding="async"
            data-fallback-target
          />
          <div
            data-fallback
            class={[
              "w-full h-full flex flex-col items-center justify-center bg-gradient-to-br from-zinc-800 to-zinc-900 p-2 text-center",
              @image_url && "hidden"
            ]}
          >
            <.icon name="hero-tv" class="size-5 sm:size-8 text-brand/60 mb-1" />
            <span class="text-2xs sm:text-xs text-text-muted leading-tight line-clamp-2">
              {@channel.name}
            </span>
          </div>
        </div>
        <div class="absolute top-1 left-1 sm:top-2 sm:left-2 flex items-center gap-0.5 sm:gap-1 px-1 sm:px-1.5 py-0.5 bg-brand rounded text-2xs sm:text-xs text-white font-semibold">
          <span class="w-1 h-1 sm:w-1.5 sm:h-1.5 bg-white rounded-full animate-pulse" /> AO VIVO
        </div>
        <div class="absolute inset-0 bg-black/30 opacity-0 group-hover:opacity-100 transition-opacity duration-200 hidden sm:flex items-center justify-center">
          <.icon name="hero-play-solid" class="size-8 text-white/90 drop-shadow-lg" />
        </div>
      </div>
      <div class="px-0.5 pt-1.5 sm:pt-2">
        <h3 class="mt-0.5 truncate text-[11px] font-medium leading-tight text-text-primary transition-colors group-hover:text-brand sm:text-sm sm:leading-normal">
          {@channel.name}
        </h3>
      </div>
    </.link>
    """
  end

  def history_item(assigns) do
    assigns =
      assigns
      |> assign_new(:class, fn -> nil end)
      |> assign(:image_url, ImageProxy.browser_image(assigns.entry.content_icon))

    ~H"""
    <.link
      href={watch_path(@entry.content_type, @entry.content_id)}
      class={[
        "group block w-[58vw] min-w-[196px] max-w-[230px] flex-shrink-0 snap-start transition-all duration-300 sm:w-[220px] sm:max-w-none lg:w-[240px]",
        @class
      ]}
    >
      <div class="relative flex aspect-video items-center justify-center overflow-hidden rounded-md bg-surface-hover shadow-sm transition-all duration-300 group-hover:-translate-y-1 group-hover:shadow-xl group-hover:shadow-brand/20 sm:rounded-lg">
        <div id={"history-img-#{@entry.id}"} phx-hook="ImageFallback" class="w-full h-full">
          <img
            :if={@image_url}
            src={@image_url}
            alt={@entry.content_name}
            class="w-full h-full object-cover"
            loading="lazy"
            decoding="async"
            data-fallback-target
          />
          <div
            data-fallback
            class={[
              "w-full h-full flex items-center justify-center text-text-muted",
              @image_url && "hidden"
            ]}
          >
            <.icon name={content_type_icon(@entry.content_type)} class="size-8 sm:size-12" />
          </div>
        </div>
        <div
          :if={@entry.progress_seconds && @entry.duration_seconds}
          class="absolute bottom-0 left-0 right-0 h-1 bg-white/30"
        >
          <div class="h-full bg-brand" style={"width: #{progress_percent(@entry)}%"} />
        </div>
        <div class="absolute inset-0 bg-black/30 opacity-0 group-hover:opacity-100 transition-opacity duration-200 hidden sm:flex items-center justify-center">
          <.icon name="hero-play-solid" class="size-8 text-white/90 drop-shadow-lg" />
        </div>
      </div>
      <div class="pt-2 px-0.5">
        <h3 class="text-xs sm:text-sm font-medium text-text-primary truncate group-hover:text-brand transition-colors">
          {@entry.content_name || "Desconhecido"}
        </h3>
        <p class="text-2xs text-text-muted flex items-center gap-1 sm:gap-2 mt-1">
          <span class="px-1 sm:px-1.5 py-0.5 rounded bg-surface-hover text-text-secondary">
            {format_content_type(@entry.content_type)}
          </span>
          <span>{format_relative_time(@entry.watched_at)}</span>
        </p>
      </div>
    </.link>
    """
  end

  def favorite_item(assigns) do
    assigns =
      assigns
      |> assign_new(:class, fn -> nil end)
      |> assign(:image_url, ImageProxy.browser_image(assigns.favorite.content_icon))

    ~H"""
    <.link
      href={watch_path(@favorite.content_type, @favorite.content_id)}
      class={[
        "content-card group w-[30vw] min-w-[104px] max-w-[122px] flex-shrink-0 snap-start overflow-hidden rounded-md bg-surface transition-transform duration-300 hover:-translate-y-1 sm:w-[96px] sm:max-w-none sm:rounded-lg lg:w-[108px]",
        @class
      ]}
    >
      <div class="relative flex aspect-[2/3] items-center justify-center bg-surface-hover">
        <div
          id={"fav-img-#{@favorite.content_type}-#{@favorite.content_id}"}
          phx-hook="ImageFallback"
          class="w-full h-full"
        >
          <img
            :if={@image_url}
            src={@image_url}
            alt={@favorite.content_name}
            class="w-full h-full object-cover"
            loading="lazy"
            decoding="async"
            data-fallback-target
          />
          <div
            data-fallback
            class={[
              "w-full h-full flex items-center justify-center text-text-muted",
              @image_url && "hidden"
            ]}
          >
            <.icon name={content_type_icon(@favorite.content_type)} class="size-6 sm:size-10" />
          </div>
        </div>
        <div class="absolute inset-0 bg-black/30 opacity-0 group-hover:opacity-100 transition-opacity duration-200 hidden sm:flex items-center justify-center">
          <.icon name="hero-play-solid" class="size-8 text-white/90 drop-shadow-lg" />
        </div>
      </div>
    </.link>
    """
  end
end
