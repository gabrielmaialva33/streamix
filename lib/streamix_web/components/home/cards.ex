defmodule StreamixWeb.Home.Cards do
  @moduledoc """
  Card components used by the home carousels.
  """

  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import StreamixWeb.ContentComponents
  import StreamixWeb.CoreComponents
  import StreamixWeb.Home.Helpers

  alias StreamixWeb.Helpers.ImageProxy

  def render_movie_card(assigns) do
    assigns = assigns |> assign_new(:class, fn -> nil end) |> assign_new(:progress, fn -> nil end)

    ~H"""
    <div class={["w-full sm:w-[132px] lg:w-[148px] sm:flex-shrink-0", @class]}>
      <.movie_card
        movie={@movie}
        progress={@progress}
        show_favorite={false}
        on_play="play_movie"
        on_details="play_movie"
      />
    </div>
    """
  end

  def render_series_card(assigns) do
    assigns = assigns |> assign_new(:class, fn -> nil end) |> assign_new(:progress, fn -> nil end)

    ~H"""
    <div class={["w-full sm:w-[132px] lg:w-[148px] sm:flex-shrink-0", @class]}>
      <.series_card
        series={@series}
        progress={@progress}
        show_favorite={false}
        on_click="view_series"
      />
    </div>
    """
  end

  def channel_card(assigns) do
    assigns = assign_new(assigns, :class, fn -> nil end)

    ~H"""
    <.link
      navigate={~p"/watch/live_channel/#{@channel.id}"}
      class={[
        "group block transition-all duration-300 content-card w-full sm:w-[150px] lg:w-[176px]",
        @class
      ]}
    >
      <div class="aspect-video bg-surface-hover relative flex items-center justify-center rounded-md sm:rounded-lg overflow-hidden shadow-sm group-hover:shadow-xl group-hover:shadow-brand/20 transition-all duration-300 group-hover:-translate-y-1">
        <div id={"home-ch-img-#{@channel.id}"} phx-hook="ImageFallback" class="w-full h-full">
          <img
            :if={@channel.stream_icon not in [nil, ""]}
            src={ImageProxy.proxy(@channel.stream_icon)}
            alt={@channel.name}
            class="w-full h-full object-contain p-1.5 sm:p-2 animate-fade-in"
            loading="lazy"
            data-fallback-target
          />
          <div
            data-fallback
            class={[
              "w-full h-full flex flex-col items-center justify-center bg-gradient-to-br from-zinc-800 to-zinc-900 p-2 text-center",
              @channel.stream_icon not in [nil, ""] && "hidden"
            ]}
          >
            <.icon name="hero-tv" class="size-5 sm:size-8 text-brand/60 mb-1" />
            <span class="text-[8px] sm:text-xs text-text-muted leading-tight line-clamp-2">
              {@channel.name}
            </span>
          </div>
        </div>
        <div class="absolute top-1 left-1 sm:top-2 sm:left-2 flex items-center gap-0.5 sm:gap-1 px-1 sm:px-1.5 py-0.5 bg-brand rounded text-[8px] sm:text-xs text-white font-semibold">
          <span class="w-1 h-1 sm:w-1.5 sm:h-1.5 bg-white rounded-full animate-pulse" /> AO VIVO
        </div>
        <div class="absolute inset-0 bg-black/30 opacity-0 group-hover:opacity-100 transition-opacity duration-200 hidden sm:flex items-center justify-center">
          <.icon name="hero-play-solid" class="size-8 text-white/90 drop-shadow-lg" />
        </div>
      </div>
      <div class="pt-1.5 sm:pt-2 px-0.5">
        <h3 class="text-[11px] sm:text-sm font-medium text-text-primary truncate group-hover:text-brand transition-colors mt-0.5">
          {@channel.name}
        </h3>
      </div>
    </.link>
    """
  end

  def history_item(assigns) do
    assigns = assign_new(assigns, :class, fn -> nil end)

    ~H"""
    <.link
      navigate={watch_path(@entry.content_type, @entry.content_id)}
      class={[
        "group flex-shrink-0 w-full sm:w-[220px] lg:w-[240px] block transition-all duration-300",
        @class
      ]}
    >
      <div class="aspect-video bg-surface-hover relative flex items-center justify-center rounded-md sm:rounded-lg overflow-hidden shadow-sm group-hover:shadow-xl group-hover:shadow-brand/20 transition-all duration-300 group-hover:-translate-y-1">
        <div id={"history-img-#{@entry.id}"} phx-hook="ImageFallback" class="w-full h-full">
          <img
            :if={@entry.content_icon}
            src={ImageProxy.proxy(@entry.content_icon)}
            alt={@entry.content_name}
            class="w-full h-full object-cover"
            loading="lazy"
            data-fallback-target
          />
          <div
            data-fallback
            class={[
              "w-full h-full flex items-center justify-center text-text-muted",
              @entry.content_icon && "hidden"
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
        <p class="text-[10px] sm:text-xs text-text-muted flex items-center gap-1 sm:gap-2 mt-1">
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
    assigns = assign_new(assigns, :class, fn -> nil end)

    ~H"""
    <.link
      navigate={watch_path(@favorite.content_type, @favorite.content_id)}
      class={[
        "group flex-shrink-0 w-full sm:w-[96px] lg:w-[108px] rounded-lg overflow-hidden bg-surface content-card transition-transform duration-300 hover:-translate-y-1",
        @class
      ]}
    >
      <div class="aspect-[2/3] bg-surface-hover relative flex items-center justify-center">
        <div
          id={"fav-img-#{@favorite.content_type}-#{@favorite.content_id}"}
          phx-hook="ImageFallback"
          class="w-full h-full"
        >
          <img
            :if={@favorite.content_icon}
            src={ImageProxy.proxy(@favorite.content_icon)}
            alt={@favorite.content_name}
            class="w-full h-full object-cover"
            loading="lazy"
            data-fallback-target
          />
          <div
            data-fallback
            class={[
              "w-full h-full flex items-center justify-center text-text-muted",
              @favorite.content_icon && "hidden"
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
