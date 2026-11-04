defmodule StreamixWeb.Gindex.EpisodeComponents do
  @moduledoc "Episode rows shared by GIndex seasons and anime releases."
  use Phoenix.Component
  import StreamixWeb.CoreComponents, only: [badge: 1, icon: 1]
  alias StreamixWeb.Gindex.DetailHelpers, as: DH

  attr :episode, :map, required: true
  attr :season_number, :integer, required: true

  def episode_item(assigns) do
    ~H"""
    <div
      class="flex gap-2 sm:gap-4 p-3 sm:p-4 hover:bg-surface-hover cursor-pointer transition-colors group touch-manipulation"
      phx-click="play_episode"
      phx-value-id={@episode.id}
    >
      <div class="flex-shrink-0 w-6 sm:w-8 text-center">
        <span class="text-lg sm:text-2xl font-bold text-text-secondary/30">
          {@episode.episode_num}
        </span>
      </div>

      <div class="relative flex-shrink-0 w-24 sm:w-36 aspect-video bg-surface-hover rounded-lg overflow-hidden">
        <div class="w-full h-full flex items-center justify-center bg-surface">
          <.icon name="hero-play-circle" class="size-6 sm:size-10 text-text-secondary/30" />
        </div>

        <div class="absolute inset-0 bg-black/50 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <div class="w-8 h-8 sm:w-10 sm:h-10 rounded-full bg-white flex items-center justify-center">
            <.icon name="hero-play-solid" class="size-4 sm:size-5 text-black ml-0.5" />
          </div>
        </div>
      </div>

      <div class="flex-1 min-w-0">
        <h4 class="font-medium text-sm sm:text-base text-text-primary group-hover:text-brand truncate">
          {DH.episode_title(@episode, @season_number)}
        </h4>
        <div class="flex items-center gap-2 mt-1">
          <.badge
            :if={@episode.container_extension}
            variant="surface"
            size="sm"
          >
            {String.upcase(@episode.container_extension)}
          </.badge>
        </div>
      </div>
    </div>
    """
  end
end
