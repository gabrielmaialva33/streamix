defmodule StreamixWeb.App.Feedback do
  @moduledoc """
  Feedback, loading, and compact library-card components.
  """

  use Phoenix.Component

  import StreamixWeb.CoreComponents

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :message, :string, default: nil
  slot :action

  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-16 text-center">
      <div class="rounded-full bg-surface-hover p-6 mb-4">
        <.icon name={@icon} class="size-12 text-text-muted" />
      </div>
      <h3 class="text-lg font-medium text-text-primary mb-1">{@title}</h3>
      <p :if={@message} class="text-text-secondary mb-6 max-w-md">{@message}</p>
      {render_slot(@action)}
    </div>
    """
  end

  attr :size, :string, default: "md", values: ~w(sm md lg)

  def loading_spinner(assigns) do
    size_class =
      case assigns.size do
        "sm" -> "size-4"
        "md" -> "size-6"
        "lg" -> "size-8"
      end

    assigns = assign(assigns, :size_class, size_class)

    ~H"""
    <svg class={["animate-spin text-brand", @size_class]} fill="none" viewBox="0 0 24 24">
      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
      </circle>
      <path
        class="opacity-75"
        fill="currentColor"
        d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
      >
      </path>
    </svg>
    """
  end

  attr :entry, :map, required: true

  def history_card_v2(assigns) do
    ~H"""
    <div class="group flex items-center gap-3 sm:gap-4 p-2 sm:p-3 rounded-xl cursor-pointer transition-all duration-300 hover:bg-surface-hover/50 hover:-translate-y-0.5 hover:shadow-lg hover:shadow-brand/5 border border-transparent hover:border-border/40">
      <div class="w-16 h-12 sm:w-20 sm:h-14 rounded-lg bg-surface-hover flex items-center justify-center shrink-0 overflow-hidden shadow-sm group-hover:shadow-md transition-shadow">
        <img
          :if={@entry.content_icon}
          src={@entry.content_icon}
          alt={@entry.content_name}
          class="w-full h-full object-contain"
          loading="lazy"
        />
        <.icon
          :if={!@entry.content_icon}
          name={content_type_icon(@entry.content_type)}
          class="size-6 text-text-muted"
        />
      </div>
      <div class="flex-1 min-w-0">
        <h4 class="font-medium text-sm sm:text-base text-text-primary truncate group-hover:text-brand transition-colors">
          {@entry.content_name || "Desconhecido"}
        </h4>
        <p class="text-sm text-text-secondary flex items-center gap-2">
          <span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs bg-surface-hover text-text-muted">
            {format_content_type(@entry.content_type)}
          </span>
          <span>{format_relative_time(@entry.watched_at)}</span>
          <span :if={@entry.duration_seconds}>- {format_duration(@entry.duration_seconds)}</span>
        </p>
      </div>
      <.icon name="hero-play-circle" class="size-8 text-brand shrink-0" />
    </div>
    """
  end

  attr :favorite, :map, required: true

  def favorite_card(assigns) do
    ~H"""
    <div class="group cursor-pointer flex flex-col gap-1 sm:gap-2 transition-all duration-300">
      <div class="relative aspect-video bg-surface-hover flex items-center justify-center rounded-lg overflow-hidden shadow-md group-hover:shadow-xl group-hover:shadow-brand/20 transition-all duration-300 group-hover:-translate-y-1">
        <img
          :if={@favorite.content_icon}
          src={@favorite.content_icon}
          alt={@favorite.content_name}
          class="w-full h-full object-contain p-2"
          loading="lazy"
        />
        <.icon
          :if={!@favorite.content_icon}
          name={content_type_icon(@favorite.content_type)}
          class="size-12 text-text-muted"
        />
        <div class="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <.icon name="hero-play-circle-solid" class="size-12 text-brand" />
        </div>
      </div>
      <div class="px-0.5 sm:px-1">
        <h3
          class="font-medium text-sm text-text-primary truncate group-hover:text-brand transition-colors mt-0.5"
          title={@favorite.content_name}
        >
          {@favorite.content_name || "Desconhecido"}
        </h3>
        <span class="inline-flex items-center mt-1 px-1.5 py-0.5 rounded text-xs bg-surface-hover text-text-muted">
          {format_content_type(@favorite.content_type)}
        </span>
      </div>
    </div>
    """
  end

  defp content_type_icon("live_channel"), do: "hero-tv"
  defp content_type_icon("movie"), do: "hero-film"
  defp content_type_icon("series"), do: "hero-video-camera"
  defp content_type_icon("episode"), do: "hero-play"
  defp content_type_icon(_), do: "hero-play-circle"

  defp format_content_type("live_channel"), do: "Ao Vivo"
  defp format_content_type("movie"), do: "Filme"
  defp format_content_type("series"), do: "Série"
  defp format_content_type("episode"), do: "Episódio"
  defp format_content_type(type), do: type || "Desconhecido"

  defp format_relative_time(nil), do: "Nunca"

  defp format_relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "agora mesmo"
      diff < 3600 -> "#{div(diff, 60)}min atrás"
      diff < 86_400 -> "#{div(diff, 3600)}h atrás"
      true -> "#{div(diff, 86_400)}d atrás"
    end
  end

  defp format_duration(seconds) when is_integer(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m"
      true -> "< 1m"
    end
  end

  defp format_duration(_), do: ""
end
