defmodule StreamixWeb.Content.DetailComponents.Actions do
  @moduledoc """
  Playback, favorite, trailer, and external-link actions for content details.
  """

  use Phoenix.Component

  import StreamixWeb.CoreComponents, only: [icon: 1]

  attr :event, :string, required: true
  attr :label, :string, required: true

  def play_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@event}
      class="inline-flex min-h-11 items-center justify-center gap-1.5 w-full sm:w-auto px-4 sm:px-8 py-2.5 sm:py-3.5 bg-brand text-white font-bold rounded-lg hover:bg-brand-hover transition-colors shadow-card text-xs sm:text-base focus:outline-none focus:ring-2 focus:ring-brand focus:ring-offset-2 focus:ring-offset-background"
    >
      <.icon name="hero-play-solid" class="size-4 sm:size-5" /> {@label}
    </button>
    """
  end

  attr :favorite?, :boolean, default: false
  attr :label_on, :string, default: "Remover dos favoritos"
  attr :label_off, :string, default: "Adicionar aos favoritos"

  def favorite_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_favorite"
      class={[
        "inline-flex items-center justify-center w-10 h-10 sm:w-12 sm:h-12 rounded-lg border-2 transition-all focus:outline-none focus:ring-2 focus:ring-brand",
        @favorite? && "bg-brand border-brand text-white",
        !@favorite? &&
          "border-border text-text-secondary hover:border-text-secondary hover:text-text-primary bg-surface"
      ]}
      aria-label={if @favorite?, do: @label_on, else: @label_off}
    >
      <.icon
        name={if @favorite?, do: "hero-heart-solid", else: "hero-heart"}
        class="size-4 sm:size-5"
      />
    </button>
    """
  end

  attr :youtube_id, :string, default: nil

  def trailer_link(assigns) do
    assigns = assign(assigns, :url, trailer_url(assigns.youtube_id))

    ~H"""
    <a
      :if={@url}
      href={@url}
      target="_blank"
      rel="noopener noreferrer"
      class="inline-flex min-h-11 items-center gap-1.5 sm:gap-2 px-3 sm:px-5 py-2.5 sm:py-3 bg-surface border border-border text-text-primary font-semibold rounded-lg hover:bg-surface-hover transition-colors text-sm"
    >
      <.icon name="hero-play-circle" class="size-4 sm:size-5 text-brand" /> Trailer
    </a>
    """
  end

  attr :tmdb_id, :any, default: nil
  attr :type, :string, required: true, values: ["movie", "tv"]

  def tmdb_link(assigns) do
    ~H"""
    <a
      :if={@tmdb_id}
      href={"https://www.themoviedb.org/#{@type}/#{@tmdb_id}"}
      target="_blank"
      rel="noopener noreferrer"
      class="inline-flex min-h-11 items-center gap-1.5 sm:gap-2 px-3 sm:px-4 py-2.5 sm:py-3 bg-surface border border-border text-text-secondary rounded-lg hover:text-text-primary hover:bg-surface-hover transition-colors text-xs sm:text-sm"
      title="Ver no The Movie Database"
    >
      <svg class="size-3.5 sm:size-4" viewBox="0 0 24 24" fill="currentColor">
        <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z" />
      </svg>
      TMDB
    </a>
    """
  end

  defp trailer_url(youtube_id) when is_binary(youtube_id) do
    if String.contains?(youtube_id, "youtube.com") or String.contains?(youtube_id, "youtu.be") do
      youtube_id
    else
      "https://www.youtube.com/watch?v=#{youtube_id}"
    end
  end

  defp trailer_url(_), do: nil
end
