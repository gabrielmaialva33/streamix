defmodule StreamixWeb.Gindex.AnimeDetailLive do
  @moduledoc """
  LiveView for displaying GIndex anime details with releases and episodes.
  Releases are stored as "seasons" but displayed as quality variants.
  """
  use StreamixWeb, :live_view

  alias Streamix.Iptv

  import StreamixWeb.CoreComponents, only: [icon: 1]

  def mount(%{"id" => anime_id}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    case Iptv.get_gindex_anime_with_seasons(anime_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Anime nao encontrado")
         |> push_navigate(to: ~p"/browse/animes?source=gindex")}

      anime ->
        is_favorite = Iptv.is_favorite?(user_id, "series", anime.id)
        sorted_releases = Enum.sort_by(anime.seasons || [], & &1.season_number)

        first_release_id =
          case sorted_releases do
            [first | _] -> first.id
            _ -> nil
          end

        socket =
          socket
          |> assign(page_title: anime.title || anime.name)
          |> assign(current_path: "/gindex/animes/#{anime.id}")
          |> assign(anime: anime)
          |> assign(releases: sorted_releases)
          |> assign(
            expanded_releases:
              if(first_release_id, do: MapSet.new([first_release_id]), else: MapSet.new())
          )
          |> assign(is_favorite: is_favorite)
          |> assign(user_id: user_id)

        {:ok, socket}
    end
  end

  # ============================================
  # Event Handlers
  # ============================================

  def handle_event("toggle_release", %{"id" => release_id}, socket) do
    release_id = String.to_integer(release_id)
    expanded = socket.assigns.expanded_releases

    expanded =
      if MapSet.member?(expanded, release_id),
        do: MapSet.delete(expanded, release_id),
        else: MapSet.put(expanded, release_id)

    {:noreply, assign(socket, expanded_releases: expanded)}
  end

  def handle_event("play_episode", %{"id" => episode_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/watch/gindex_episode/#{episode_id}")}
  end

  def handle_event("play_first_episode", _, socket) do
    case socket.assigns.releases do
      [first_release | _] when first_release.episodes != [] ->
        [first_episode | _] = Enum.sort_by(first_release.episodes, & &1.episode_num)
        {:noreply, push_navigate(socket, to: ~p"/watch/gindex_episode/#{first_episode.id}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Nenhum episodio disponivel")}
    end
  end

  def handle_event("toggle_favorite", _, socket) do
    user_id = socket.assigns.user_id
    anime = socket.assigns.anime
    is_favorite = socket.assigns.is_favorite

    if is_favorite do
      Iptv.remove_favorite(user_id, "series", anime.id)
    else
      Iptv.add_favorite(user_id, %{
        content_type: "series",
        content_id: anime.id,
        content_name: anime.title || anime.name,
        content_icon: anime.cover
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
            navigate={~p"/browse/animes?source=gindex"}
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
                <div class="w-full h-full flex items-center justify-center bg-gradient-to-br from-purple-900/50 to-gray-900">
                  <.icon name="hero-sparkles" class="size-12 sm:size-16 text-purple-400/30" />
                </div>
              </div>
            </div>
            
    <!-- Info -->
            <div class="flex-1 space-y-4 text-center lg:text-left">
              <!-- Title -->
              <div class="space-y-2">
                <h1 class="text-xl sm:text-3xl lg:text-4xl font-bold text-text-primary leading-tight">
                  {@anime.name}
                </h1>
                <p
                  :if={@anime.title && @anime.title != @anime.name}
                  class="text-lg text-text-secondary"
                >
                  {@anime.title}
                </p>
              </div>
              
    <!-- Meta Tags -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-2">
                <span
                  :if={@anime.year}
                  class="inline-flex items-center h-7 px-2.5 bg-surface text-text-primary rounded-md text-sm font-medium"
                >
                  {@anime.year}
                </span>
                <span class="inline-flex items-center gap-1 h-7 px-2.5 bg-surface text-text-secondary rounded-md text-sm">
                  <.icon name="hero-sparkles" class="size-3.5" />
                  {length(@releases)} releases | {@anime.episode_count || 0} eps
                </span>
                <span class="inline-flex items-center h-7 px-2.5 bg-purple-600/20 text-purple-400 rounded-md uppercase text-xs font-bold">
                  Anime
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
          
    <!-- Releases Section -->
          <div class="mt-8 sm:mt-12 space-y-4 sm:space-y-6">
            <h2 class="text-xl sm:text-2xl font-bold text-text-primary">Releases</h2>

            <div :if={Enum.empty?(@releases)} class="text-center py-8 sm:py-12">
              <.icon
                name="hero-film"
                class="size-12 sm:size-16 mx-auto mb-3 sm:mb-4 text-text-secondary/20"
              />
              <p class="text-text-secondary text-sm sm:text-base">Nenhum release disponivel</p>
            </div>

            <div class="space-y-3 sm:space-y-4">
              <.release_accordion
                :for={release <- @releases}
                release={release}
                expanded={MapSet.member?(@expanded_releases, release.id)}
              />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp release_accordion(assigns) do
    episodes = Enum.sort_by(assigns.release.episodes || [], & &1.episode_num)
    assigns = assign(assigns, :episodes, episodes)

    ~H"""
    <div class="bg-surface rounded-lg sm:rounded-xl overflow-hidden border border-border">
      <button
        type="button"
        phx-click="toggle_release"
        phx-value-id={@release.id}
        class="w-full flex items-center justify-between px-4 sm:px-6 py-3 sm:py-4 hover:bg-surface-hover transition-colors"
      >
        <div class="flex items-center gap-2 sm:gap-4">
          <span class="text-base sm:text-lg font-semibold text-text-primary truncate max-w-[200px] sm:max-w-none">
            {@release.name || "Release #{@release.season_number}"}
          </span>
          <span class="text-xs sm:text-sm text-text-secondary flex-shrink-0">
            {length(@episodes)} eps
          </span>
        </div>
        <.icon
          name="hero-chevron-down"
          class={[
            "size-4 sm:size-5 text-text-secondary transition-transform duration-200 flex-shrink-0",
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
    episode.title || episode.name || "Episodio #{episode.episode_num}"
  end
end
