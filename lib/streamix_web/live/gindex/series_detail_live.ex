defmodule StreamixWeb.Gindex.SeriesDetailLive do
  @moduledoc """
  LiveView for displaying GIndex series details with seasons and episodes.
  """
  use StreamixWeb, :live_view

  alias Streamix.Iptv

  import StreamixWeb.CoreComponents, only: [icon: 1]

  def mount(%{"id" => series_id}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    case Iptv.get_gindex_series_with_seasons(series_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Série não encontrada")
         |> push_navigate(to: ~p"/browse/series?source=gindex")}

      series ->
        is_favorite = Iptv.is_favorite?(user_id, "series", series.id)
        sorted_seasons = Enum.sort_by(series.seasons || [], & &1.season_number)

        first_season_id =
          case sorted_seasons do
            [first | _] -> first.id
            _ -> nil
          end

        socket =
          socket
          |> assign(page_title: series.title || series.name)
          |> assign(current_path: "/gindex/series/#{series.id}")
          |> assign(series: series)
          |> assign(seasons: sorted_seasons)
          |> assign(
            expanded_seasons:
              if(first_season_id, do: MapSet.new([first_season_id]), else: MapSet.new())
          )
          |> assign(is_favorite: is_favorite)
          |> assign(user_id: user_id)

        {:ok, socket}
    end
  end

  # ============================================
  # Event Handlers
  # ============================================

  def handle_event("toggle_season", %{"id" => season_id}, socket) do
    season_id = String.to_integer(season_id)
    expanded = socket.assigns.expanded_seasons

    expanded =
      if MapSet.member?(expanded, season_id),
        do: MapSet.delete(expanded, season_id),
        else: MapSet.put(expanded, season_id)

    {:noreply, assign(socket, expanded_seasons: expanded)}
  end

  def handle_event("play_episode", %{"id" => episode_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/watch/gindex_episode/#{episode_id}")}
  end

  def handle_event("play_first_episode", _, socket) do
    case socket.assigns.seasons do
      [first_season | _] when first_season.episodes != [] ->
        [first_episode | _] = Enum.sort_by(first_season.episodes, & &1.episode_num)
        {:noreply, push_navigate(socket, to: ~p"/watch/gindex_episode/#{first_episode.id}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Nenhum episódio disponível")}
    end
  end

  def handle_event("toggle_favorite", _, socket) do
    user_id = socket.assigns.user_id
    series = socket.assigns.series
    is_favorite = socket.assigns.is_favorite

    if is_favorite do
      Iptv.remove_favorite(user_id, "series", series.id)
    else
      Iptv.add_favorite(user_id, %{
        content_type: "series",
        content_id: series.id,
        content_name: series.title || series.name,
        content_icon: series.cover
      })
    end

    {:noreply, assign(socket, is_favorite: !is_favorite)}
  end

  # ============================================
  # Render
  # ============================================

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-background">
      <!-- Hero Section -->
      <div class="relative h-[40vh] sm:h-[50vh] min-h-[280px]">
        <div class="absolute inset-0">
          <div class="w-full h-full bg-gradient-to-br from-purple-900 to-gray-900" />
        </div>

        <div class="absolute inset-0 bg-gradient-to-t from-background via-background/60 to-transparent" />
        
    <!-- Back Button -->
        <div class="absolute top-4 left-4 sm:top-6 sm:left-6 z-10">
          <.link
            navigate={~p"/browse/series?source=gindex"}
            class="inline-flex items-center gap-1.5 sm:gap-2 px-3 sm:px-4 py-1.5 sm:py-2 bg-black/40 backdrop-blur-sm text-white/90 hover:text-white hover:bg-black/60 rounded-full transition-all text-xs sm:text-sm font-medium"
          >
            <.icon name="hero-arrow-left" class="size-3.5 sm:size-4" /> Voltar
          </.link>
        </div>
      </div>
      
    <!-- Content Section -->
      <div class="relative -mt-24 sm:-mt-32 px-[4%] sm:px-8 lg:px-12 pb-8 sm:pb-12">
        <div class="max-w-5xl mx-auto">
          <div class="flex flex-col lg:flex-row gap-4 sm:gap-6 lg:gap-8">
            <!-- Poster -->
            <div class="flex-shrink-0 w-32 sm:w-48 lg:w-64 mx-auto lg:mx-0">
              <div class="aspect-[2/3] rounded-lg overflow-hidden shadow-2xl ring-1 ring-white/10 bg-surface">
                <div class="w-full h-full flex items-center justify-center">
                  <.icon name="hero-tv" class="size-12 sm:size-16 text-text-secondary/30" />
                </div>
              </div>
            </div>
            
    <!-- Info -->
            <div class="flex-1 space-y-4 text-center lg:text-left">
              <!-- Title -->
              <div class="space-y-2">
                <h1 class="text-xl sm:text-3xl lg:text-4xl font-bold text-text-primary leading-tight">
                  {@series.name}
                </h1>
                <p
                  :if={@series.title && @series.title != @series.name}
                  class="text-lg text-text-secondary"
                >
                  {@series.title}
                </p>
              </div>
              
    <!-- Meta Tags -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-2">
                <span
                  :if={@series.year}
                  class="inline-flex items-center h-7 px-2.5 bg-surface text-text-primary rounded-md text-sm font-medium"
                >
                  {@series.year}
                </span>
                <span class="inline-flex items-center gap-1 h-7 px-2.5 bg-surface text-text-secondary rounded-md text-sm">
                  <.icon name="hero-tv" class="size-3.5" />
                  {length(@seasons)} temp · {@series.episode_count || 0} eps
                </span>
                <span class="inline-flex items-center h-7 px-2.5 bg-purple-600/20 text-purple-400 rounded-md uppercase text-xs font-bold">
                  GDrive
                </span>
              </div>
              
    <!-- Action Buttons -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-3 pt-4">
                <button
                  type="button"
                  phx-click="play_first_episode"
                  class="inline-flex items-center justify-center gap-2 px-6 sm:px-8 py-3 bg-purple-600 text-white font-bold rounded-lg hover:bg-purple-700 transition-colors shadow-lg shadow-purple-600/30 text-sm sm:text-base"
                >
                  <.icon name="hero-play-solid" class="size-5" /> Assistir
                </button>

                <button
                  type="button"
                  phx-click="toggle_favorite"
                  class={[
                    "inline-flex items-center justify-center w-12 h-12 rounded-lg border-2 transition-all",
                    @is_favorite && "bg-red-600 border-red-600 text-white",
                    !@is_favorite &&
                      "border-border text-text-secondary hover:border-text-secondary hover:text-text-primary bg-surface"
                  ]}
                  title={
                    if @is_favorite, do: "Remover dos favoritos", else: "Adicionar aos favoritos"
                  }
                >
                  <.icon
                    name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"}
                    class="size-5"
                  />
                </button>
              </div>
            </div>
          </div>
          
    <!-- Episodes Section -->
          <div class="mt-8 sm:mt-12 space-y-4 sm:space-y-6">
            <h2 class="text-xl sm:text-2xl font-bold text-text-primary">Episódios</h2>

            <div :if={Enum.empty?(@seasons)} class="text-center py-8 sm:py-12">
              <.icon
                name="hero-film"
                class="size-12 sm:size-16 mx-auto mb-3 sm:mb-4 text-text-secondary/20"
              />
              <p class="text-text-secondary text-sm sm:text-base">Nenhum episódio disponível</p>
            </div>

            <div class="space-y-3 sm:space-y-4">
              <.season_accordion
                :for={season <- @seasons}
                season={season}
                expanded={MapSet.member?(@expanded_seasons, season.id)}
              />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp season_accordion(assigns) do
    episodes = Enum.sort_by(assigns.season.episodes || [], & &1.episode_num)
    assigns = assign(assigns, :episodes, episodes)

    ~H"""
    <div class="bg-surface rounded-lg sm:rounded-xl overflow-hidden border border-border">
      <button
        type="button"
        phx-click="toggle_season"
        phx-value-id={@season.id}
        class="w-full flex items-center justify-between px-4 sm:px-6 py-3 sm:py-4 hover:bg-surface-hover transition-colors"
      >
        <div class="flex items-center gap-2 sm:gap-4">
          <span class="text-base sm:text-lg font-semibold text-text-primary">
            Temporada {@season.season_number}
          </span>
          <span class="text-xs sm:text-sm text-text-secondary">{length(@episodes)} eps</span>
        </div>
        <.icon
          name="hero-chevron-down"
          class={[
            "size-4 sm:size-5 text-text-secondary transition-transform duration-200",
            @expanded && "rotate-180"
          ]}
        />
      </button>

      <div :if={@expanded} class="border-t border-border">
        <div class="divide-y divide-border">
          <.episode_item :for={episode <- @episodes} episode={episode} />
        </div>
      </div>
    </div>
    """
  end

  defp episode_item(assigns) do
    ~H"""
    <div
      class="flex gap-2 sm:gap-4 p-3 sm:p-4 hover:bg-surface-hover cursor-pointer transition-colors group"
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
        <h4 class="font-medium text-sm sm:text-base text-text-primary group-hover:text-purple-400 truncate">
          {episode_title(@episode)}
        </h4>
        <div class="flex items-center gap-2 mt-1">
          <span
            :if={@episode.container_extension}
            class="text-[10px] sm:text-xs px-1.5 py-0.5 bg-purple-600/20 text-purple-400 rounded uppercase font-bold"
          >
            {@episode.container_extension}
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp episode_title(episode) do
    episode.title || episode.name || "Episódio #{episode.episode_num}"
  end
end
