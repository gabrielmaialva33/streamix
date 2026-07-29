defmodule StreamixWeb.Content.EpisodeDetailLive do
  @moduledoc """
  LiveView for displaying episode details before playback.
  Works for both /browse/series/:series_id/episode/:id (global provider)
  and /providers/:provider_id/series/:series_id/episode/:id (user provider).
  """
  use StreamixWeb, :live_view

  alias Streamix.Iptv.Series
  alias StreamixWeb.Content.Detail
  alias StreamixWeb.PlayerHelpers

  import StreamixWeb.CoreComponents, only: [icon: 1]

  import StreamixWeb.Content.DetailComponents,
    only: [
      content_rating_badge: 1,
      date_badge: 1,
      detail_hero: 1,
      duration_badge: 1,
      episode_navigation: 1,
      extension_badge: 1,
      favorite_button: 1,
      rating_badge: 1,
      synopsis_section: 1
    ]

  # Mount for /providers/:provider_id/series/:series_id/episode/:id (user
  # provider). Must come first: the browse clause's pattern also matches
  # these params.
  def mount(
        %{"provider_id" => _, "series_id" => series_id, "id" => episode_id} = params,
        _session,
        socket
      ) do
    user_id = socket.assigns.current_scope.user.id

    Detail.with_provider(socket, :provider, params, fn provider ->
      mount_with_provider(socket, provider, series_id, episode_id, user_id, :provider)
    end)
  end

  # Mount for /browse/series/:series_id/episode/:id (global provider)
  def mount(%{"series_id" => series_id, "id" => episode_id}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    Detail.with_provider(socket, :browse, %{}, fn provider ->
      mount_with_provider(socket, provider, series_id, episode_id, user_id, :browse)
    end)
  end

  defp mount_with_provider(socket, provider, series_id, episode_id, user_id, mode) do
    episode = Detail.get_episode_with_context!(episode_id)
    series = episode.season.series

    # Verify episode belongs to the series
    if to_string(series.id) != series_id do
      {:ok,
       socket
       |> put_flash(:error, "Episódio não encontrado")
       |> push_navigate(to: back_path(mode, provider, series_id))}
    else
      mount_episode_found(socket, provider, episode, series, user_id, mode)
    end
  rescue
    Ecto.NoResultsError ->
      {:ok,
       socket
       |> put_flash(:error, "Episódio não encontrado")
       |> redirect(to: ~p"/")}
  end

  defp mount_episode_found(socket, provider, episode, series, user_id, mode) do
    is_favorite = Detail.favorite?(user_id, "series", series.id)

    # Enrich episode with TMDB data if needed
    episode = Detail.maybe_fetch_episode_info(episode)

    maybe_prewarm(socket, episode, user_id)

    navigation = Detail.episode_navigation(episode)

    current_path =
      if mode == :browse,
        do: "/browse/series/#{series.id}/episode/#{episode.id}",
        else: "/providers/#{provider.id}/series/#{series.id}/episode/#{episode.id}"

    socket =
      socket
      |> assign(page_title: episode_title(episode, series))
      |> assign(current_path: current_path)
      |> assign(provider: provider)
      |> assign(episode: episode)
      |> assign(season: navigation.season)
      |> assign(series: series)
      |> assign(lcp_image: get_episode_image(episode) || get_series_backdrop(series))
      |> assign(mode: mode)
      |> assign(is_favorite: is_favorite)
      |> assign(user_id: user_id)
      |> assign(prev_episode: navigation.prev_episode)
      |> assign(next_episode: navigation.next_episode)
      |> assign(total_episodes: navigation.total_episodes)

    {:ok, socket}
  end

  # Prewarm the upstream redirect chain — by the time the user clicks
  # "Assistir", the resolver cache is hot.
  defp maybe_prewarm(socket, episode, user_id) do
    if connected?(socket) and user_id do
      PlayerHelpers.prewarm_upstream_redirect("episode", episode, user_id)
    end

    :ok
  end

  # ============================================
  # Event Handlers
  # ============================================

  # ThemeToggle hook event (client-side theme management, no server action needed)
  def handle_event("theme_init", _params, socket), do: {:noreply, socket}

  def handle_event("play_episode", _, socket) do
    {:noreply, redirect(socket, to: ~p"/watch/episode/#{socket.assigns.episode.id}")}
  end

  def handle_event("toggle_favorite", _, socket) do
    case socket.assigns.user_id do
      nil ->
        {:noreply, put_flash(socket, :info, "Faça login para adicionar favoritos")}

      user_id ->
        series = socket.assigns.series
        is_favorite = socket.assigns.is_favorite

        {:noreply,
         assign(socket, is_favorite: Detail.toggle_series_favorite(user_id, series, is_favorite))}
    end
  end

  # ============================================
  # Render
  # ============================================

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-background">
      <.detail_hero
        image={get_episode_image(@episode) || get_series_backdrop(@series)}
        alt={episode_title(@episode, @series)}
        back_path={back_path(@mode, @provider, @series.id)}
        height_class="h-[35vh] sm:h-[45vh] lg:h-[50vh]"
        min_height_class="min-h-[240px] sm:min-h-[300px]"
        compact_back?
      />
      
    <!-- Content Section -->
      <div class="relative -mt-20 sm:-mt-28 lg:-mt-32 px-[4%] sm:px-8 lg:px-12 pb-8 sm:pb-12">
        <div class="max-w-5xl mx-auto">
          <div class="flex flex-col lg:flex-row gap-4 sm:gap-6 lg:gap-8">
            <!-- Episode Thumbnail -->
            <div class="flex-shrink-0 w-full sm:w-72 lg:w-80 mx-auto lg:mx-0">
              <div class="aspect-video rounded-lg sm:rounded-xl overflow-hidden shadow-2xl ring-1 ring-white/10">
                <img
                  :if={get_episode_image(@episode)}
                  src={get_episode_image(@episode)}
                  alt={episode_title(@episode, @series)}
                  class="w-full h-full object-cover"
                  loading="lazy"
                  decoding="async"
                />
                <div
                  :if={!get_episode_image(@episode)}
                  class="w-full h-full bg-surface flex items-center justify-center"
                >
                  <.icon name="hero-play-circle" class="size-10 sm:size-16 text-text-secondary/30" />
                </div>
              </div>
            </div>
            
    <!-- Info -->
            <div class="flex-1 space-y-3 sm:space-y-4 lg:space-y-5 text-center lg:text-left">
              <!-- Series & Season Info -->
              <div class="space-y-0.5 sm:space-y-1">
                <.link
                  navigate={series_path(@mode, @provider, @series.id)}
                  class="text-brand hover:underline text-xs sm:text-sm font-medium"
                >
                  {@series.title || @series.name}
                </.link>
                <p class="text-text-secondary text-xs sm:text-sm">
                  T{@season.season_number} · Ep {@episode.episode_num} de {@total_episodes}
                </p>
              </div>
              
    <!-- Episode Title -->
              <h1 class="text-xl sm:text-2xl lg:text-4xl font-bold text-text-primary leading-tight">
                {episode_display_title(@episode)}
              </h1>
              
    <!-- Meta Tags -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-1.5 sm:gap-2">
                <.content_rating_badge rating={@series.content_rating} />
                <.rating_badge
                  rating={@episode.rating}
                  divide_by_two?={false}
                  class="font-medium"
                />
                <.date_badge date={@episode.air_date} />
                <.duration_badge seconds={@episode.duration_secs} />
                <.extension_badge extension={@episode.container_extension} />
              </div>
              
    <!-- Action Buttons -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-2 sm:gap-3 pt-2">
                <button
                  type="button"
                  phx-click="play_episode"
                  class="inline-flex items-center justify-center gap-2 w-full sm:w-auto px-6 sm:px-8 py-3 sm:py-3.5 bg-brand text-white font-bold rounded-lg hover:bg-brand-hover transition-colors shadow-card text-sm sm:text-base focus:outline-none focus:ring-2 focus:ring-brand focus:ring-offset-2 focus:ring-offset-background"
                >
                  <.icon name="hero-play-solid" class="size-4 sm:size-5" /> Assistir Episódio
                </button>

                <StreamixWeb.WatchPartyComponents.create_party_button
                  content_type="episode"
                  content_id={@episode.id}
                />

                <.favorite_button
                  favorite?={@is_favorite}
                  label_on="Série nos favoritos"
                  label_off="Adicionar série aos favoritos"
                />
              </div>
              
    <!-- Synopsis -->
              <.synopsis_section text={@episode.plot} />
              
    <!-- Series Synopsis (if no episode synopsis) -->
              <.synopsis_section
                :if={!present?(@episode.plot)}
                title="Sobre a Série"
                text={@series.plot}
                class="line-clamp-4"
              />
            </div>
          </div>
          
    <!-- Episode Navigation -->
          <.episode_navigation
            mode={@mode}
            provider={@provider}
            series={@series}
            prev_episode={@prev_episode}
            next_episode={@next_episode}
          />
        </div>
      </div>
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp back_path(:browse, _provider, series_id), do: ~p"/browse/series/#{series_id}"

  defp back_path(:provider, provider, series_id),
    do: ~p"/providers/#{provider.id}/series/#{series_id}"

  defp series_path(:browse, _provider, series_id), do: ~p"/browse/series/#{series_id}"

  defp series_path(:provider, provider, series_id),
    do: ~p"/providers/#{provider.id}/series/#{series_id}"

  defp episode_title(episode, series) do
    base = series.title || series.name
    "S#{episode.season.season_number}E#{episode.episode_num} - #{base}"
  end

  defp episode_display_title(episode) do
    cond do
      episode.name && episode.name != "" -> episode.name
      episode.title && episode.title != "" -> episode.title
      true -> "Episódio #{episode.episode_num}"
    end
  end

  defp get_episode_image(episode) do
    episode.still_path || episode.cover
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp get_series_backdrop(%Series{} = series) do
    case Series.backdrop_urls(series) do
      [url | _] -> url
      _ -> get_series_backdrop_fallback(series)
    end
  end

  defp get_series_backdrop(_), do: nil

  defp get_series_backdrop_fallback(%{cover: cover}) when is_binary(cover), do: cover
  defp get_series_backdrop_fallback(_), do: nil
end
