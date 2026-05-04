defmodule StreamixWeb.Content.DetailComponents do
  @moduledoc "Detail and modal components"
  use Phoenix.Component
  use StreamixWeb, :verified_routes
  import StreamixWeb.CoreComponents
  # Shared helpers and internal formats
  import StreamixWeb.Content.CardComponents
  import StreamixWeb.Content.HelperComponents

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
            fetchpriority="high"
            decoding="async"
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
              <.icon name="hero-star-solid" class="size-4 text-warning" />
              {format_rating(@content.rating)}
            </span>
            <span :if={Map.get(@content, :genres, []) != []}>{format_genre_names(@content)}</span>
            <span :if={Map.get(@content, :duration_secs)}>
              {format_duration(@content.duration_secs)}
            </span>
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
end
