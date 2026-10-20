defmodule StreamixWeb.Gindex.SeriesDetailLive do
  @moduledoc """
  LiveView for displaying GIndex series details with seasons and episodes.
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

  import StreamixWeb.Content.DetailComponents.Badges,
    only: [rating_badge: 1, series_count_badge: 1, year_badge: 1]

  import StreamixWeb.Helpers.Params, only: [parse_positive_integer: 1]

  def mount(%{"id" => series_id}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    case Streamix.Catalog.get_gindex_series_with_seasons(series_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Série não encontrada")
         |> push_navigate(to: ~p"/browse/series?source=gindex")}

      series ->
        is_favorite = Library.favorite?(user_id, "series", series.id)
        sorted_seasons = Enum.sort_by(series.seasons || [], & &1.season_number)
        display_title = DH.display_title(series)

        first_season_id =
          case sorted_seasons do
            [first | _] -> first.id
            _ -> nil
          end

        socket =
          socket
          |> assign(page_title: display_title)
          |> assign(display_title: display_title)
          |> assign(source_badges: SourceBadges.badges(series))
          |> assign(current_path: "/gindex/series/#{series.id}")
          |> assign(series: series)
          |> assign(lcp_image: series.cover)
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

  def handle_event("toggle_season", %{"id" => season_id}, socket) do
    case parse_positive_integer(season_id) do
      {:ok, season_id} ->
        expanded = socket.assigns.expanded_seasons

        expanded =
          if MapSet.member?(expanded, season_id),
            do: MapSet.delete(expanded, season_id),
            else: MapSet.put(expanded, season_id)

        {:noreply, assign(socket, expanded_seasons: expanded)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("play_episode", %{"id" => episode_id}, socket) do
    {:noreply, redirect(socket, to: ~p"/watch/gindex_episode/#{episode_id}")}
  end

  def handle_event("play_first_episode", _, socket) do
    case socket.assigns.seasons do
      [first_season | _] when first_season.episodes != [] ->
        [first_episode | _] = Enum.sort_by(first_season.episodes, & &1.episode_num)
        {:noreply, redirect(socket, to: ~p"/watch/gindex_episode/#{first_episode.id}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Nenhum episódio disponível")}
    end
  end

  def handle_event("toggle_favorite", _, socket) do
    user_id = socket.assigns.user_id
    series = socket.assigns.series
    is_favorite = socket.assigns.is_favorite

    result =
      FavoriteState.toggle(user_id, "series", series.id, %{
        content_name: series.title || series.name,
        content_icon: series.cover
      })

    {:noreply, assign(socket, is_favorite: FavoriteState.preserve_boolean(is_favorite, result))}
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-background">
      <.detail_hero
        image={@series.cover}
        alt={@display_title}
        back_path={~p"/browse/series?source=gindex"}
      />

      <div class="relative -mt-16 sm:-mt-32 lg:-mt-40 px-3 sm:px-8 lg:px-12 pb-6 sm:pb-12">
        <div class="max-w-7xl mx-auto">
          <div class="flex flex-col lg:flex-row gap-3 sm:gap-6 lg:gap-8">
            <div class="flex-shrink-0 w-24 sm:w-48 lg:w-72 mx-auto lg:mx-0">
              <div class="aspect-[2/3] rounded-lg sm:rounded-xl overflow-hidden shadow-2xl ring-1 ring-white/10 bg-surface">
                <img
                  :if={@series.cover}
                  src={@series.cover}
                  alt={@display_title}
                  class="w-full h-full object-cover"
                  loading="lazy"
                  referrerpolicy="no-referrer"
                />
                <div
                  :if={is_nil(@series.cover)}
                  class="w-full h-full flex items-center justify-center bg-surface-hover"
                >
                  <.icon name="hero-tv" class="size-12 sm:size-16 text-text-secondary/30" />
                </div>
              </div>
            </div>

            <div class="flex-1 space-y-2 sm:space-y-4 lg:space-y-6 text-center lg:text-left">
              <.detail_title title={@display_title} />

              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-1.5 sm:gap-2">
                <.rating_badge rating={@series.rating} />
                <.year_badge year={@series.year} />
                <.series_count_badge seasons={@seasons} />
                <.badge
                  :if={Map.get(@series, :dub_available)}
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

              <.synopsis_section text={@series.plot} />
            </div>
          </div>

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
              <.render_season_accordion
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

  defp render_season_accordion(assigns) do
    episodes = Enum.sort_by(assigns.season.episodes || [], & &1.episode_num)
    assigns = assign(assigns, :episodes, episodes)

    ~H"""
    <div class="bg-surface rounded-lg sm:rounded-xl overflow-hidden border border-border">
      <button
        type="button"
        phx-click="toggle_season"
        phx-value-id={@season.id}
        class="w-full flex items-center justify-between px-4 sm:px-6 py-3 sm:py-4 hover:bg-surface-hover transition-colors touch-manipulation"
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
          <.episode_item
            :for={episode <- @episodes}
            episode={episode}
            season_number={@season.season_number}
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
end
