defmodule StreamixWeb.Gindex.AnimeDetailLive do
  @moduledoc """
  LiveView for displaying GIndex anime details with releases and episodes.
  Releases are stored as "seasons" but displayed as quality variants.
  """
  use StreamixWeb, :live_view
  alias Streamix.Library
  alias StreamixWeb.Content.FavoriteState
  alias StreamixWeb.Content.SourceBadges
  alias StreamixWeb.Gindex.DetailHelpers, as: DH

  import StreamixWeb.CoreComponents, only: [badge: 1, icon: 1]

  import StreamixWeb.Content.DetailComponents,
    only: [detail_hero: 1, detail_title: 1, synopsis_section: 1]

  import StreamixWeb.Content.DetailComponents.Actions, only: [favorite_button: 1, play_button: 1]
  import StreamixWeb.Content.DetailComponents.Badges, only: [rating_badge: 1, year_badge: 1]
  import StreamixWeb.Helpers.Params, only: [parse_positive_integer: 1]

  def mount(%{"id" => anime_id}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    case Streamix.Catalog.get_gindex_anime_with_seasons(anime_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Anime não encontrado")
         |> push_navigate(to: ~p"/browse/animes?source=gindex")}

      anime ->
        is_favorite =
          Library.favorite?(socket.assigns.current_scope.library_key, "series", anime.id)

        sorted_releases = Enum.sort_by(anime.seasons || [], & &1.season_number)
        display_title = DH.display_title(anime)

        first_release_id =
          case sorted_releases do
            [first | _] -> first.id
            _ -> nil
          end

        socket =
          socket
          |> assign(page_title: display_title)
          |> assign(current_path: "/gindex/animes/#{anime.id}")
          |> assign(anime: anime)
          |> assign(lcp_image: anime.cover)
          |> assign(display_title: display_title)
          |> assign(source_badges: SourceBadges.badges(anime))
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

  def handle_event("toggle_release", %{"id" => release_id}, socket) do
    case parse_positive_integer(release_id) do
      {:ok, release_id} ->
        expanded = socket.assigns.expanded_releases

        expanded =
          if MapSet.member?(expanded, release_id),
            do: MapSet.delete(expanded, release_id),
            else: MapSet.put(expanded, release_id)

        {:noreply, assign(socket, expanded_releases: expanded)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("play_episode", %{"id" => episode_id}, socket) do
    {:noreply, redirect(socket, to: ~p"/watch/gindex_episode/#{episode_id}")}
  end

  def handle_event("play_first_episode", _, socket) do
    case socket.assigns.releases do
      [first_release | _] when first_release.episodes != [] ->
        [first_episode | _] = Enum.sort_by(first_release.episodes, & &1.episode_num)
        {:noreply, redirect(socket, to: ~p"/watch/gindex_episode/#{first_episode.id}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Nenhum episódio disponível")}
    end
  end

  def handle_event("toggle_favorite", _, socket) do
    library_key = socket.assigns.current_scope.library_key
    anime = socket.assigns.anime
    is_favorite = socket.assigns.is_favorite

    result =
      FavoriteState.toggle(library_key, "series", anime.id, %{
        content_name: anime.title || anime.name,
        content_icon: anime.cover
      })

    {:noreply, assign(socket, is_favorite: FavoriteState.preserve_boolean(is_favorite, result))}
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-background">
      <.detail_hero
        image={@anime.cover}
        alt={@display_title}
        back_path={~p"/browse/animes?source=gindex"}
      />

      <div class="relative -mt-16 sm:-mt-32 lg:-mt-40 px-3 sm:px-8 lg:px-12 pb-6 sm:pb-12">
        <div class="max-w-7xl mx-auto">
          <div class="flex flex-col lg:flex-row gap-3 sm:gap-6 lg:gap-8">
            <div class="flex-shrink-0 w-24 sm:w-48 lg:w-72 mx-auto lg:mx-0">
              <div class="aspect-[2/3] rounded-lg sm:rounded-xl overflow-hidden shadow-2xl ring-1 ring-white/10 bg-surface">
                <img
                  :if={@anime.cover}
                  src={@anime.cover}
                  alt={@display_title}
                  class="w-full h-full object-cover"
                  loading="lazy"
                  referrerpolicy="no-referrer"
                />
                <div
                  :if={is_nil(@anime.cover)}
                  class="w-full h-full flex items-center justify-center bg-surface-hover"
                >
                  <.icon name="hero-tv" class="size-12 sm:size-16 text-text-secondary/30" />
                </div>
              </div>
            </div>

            <div class="flex-1 space-y-2 sm:space-y-4 lg:space-y-6 text-center lg:text-left">
              <.detail_title title={@display_title} />

              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-1.5 sm:gap-2">
                <.rating_badge rating={@anime.rating} />
                <.year_badge year={@anime.year} />
                <.badge variant="surface" size="sm">
                  <.icon name="hero-sparkles" class="size-3.5" />
                  {releases_count_label(@releases)} · {episodes_count_label(@releases)}
                </.badge>
                <.badge
                  :if={Map.get(@anime, :dub_available)}
                  variant="success"
                  size="sm"
                >
                  Dublado
                </.badge>
                <.badge
                  :for={badge <- @source_badges}
                  variant="surface"
                  size="sm"
                  data-source-badge
                >
                  {badge}
                </.badge>
              </div>

              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-2 sm:gap-3 pt-2">
                <.play_button event="play_first_episode" label="Assistir" />
                <div class="title-secondary-actions">
                  <.favorite_button favorite?={@is_favorite} />
                </div>
              </div>

              <.synopsis_section text={@anime.plot} />
            </div>
          </div>

          <div class="mt-8 sm:mt-12 space-y-4 sm:space-y-6">
            <h2 class="text-xl sm:text-2xl font-bold text-text-primary">Versões e episódios</h2>

            <div :if={Enum.empty?(@releases)} class="text-center py-8 sm:py-12">
              <.icon
                name="hero-film"
                class="size-12 sm:size-16 mx-auto mb-3 sm:mb-4 text-text-secondary/20"
              />
              <p class="text-text-secondary text-sm sm:text-base">Nenhuma versão disponível</p>
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
        class="w-full flex items-center justify-between px-4 sm:px-6 py-3 sm:py-4 hover:bg-surface-hover transition-colors touch-manipulation"
      >
        <div class="flex items-center gap-2 sm:gap-4">
          <span class="text-base sm:text-lg font-semibold text-text-primary truncate max-w-[200px] sm:max-w-none">
            {@release.name || "Versão #{@release.season_number}"}
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
          <.episode_item
            :for={episode <- @episodes}
            episode={episode}
            season_number={@release.season_number}
          />
        </div>
      </div>
    </div>
    """
  end

  defp episode_item(assigns) do
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

  defp releases_count_label(releases) do
    case length(releases) do
      1 -> "1 versão"
      n -> "#{n} versões"
    end
  end

  defp episodes_count_label(releases) do
    total = Enum.sum(Enum.map(releases, fn s -> length(s.episodes || []) end))
    "#{total} eps"
  end
end
