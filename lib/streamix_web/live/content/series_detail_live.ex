defmodule StreamixWeb.Content.SeriesDetailLive do
  @moduledoc """
  LiveView for displaying series details with seasons and episodes.
  Works for both /browse/series/:id (global provider) and /providers/:id/series/:id (user provider).
  """
  use StreamixWeb, :live_view

  alias Streamix.Iptv.Series
  alias StreamixWeb.Content.Detail

  import StreamixWeb.CoreComponents, only: [icon: 1]

  import StreamixWeb.Content.DetailComponents,
    only: [
      content_rating_badge: 1,
      credits_grid: 1,
      detail_hero: 1,
      detail_season_accordion: 1,
      detail_title: 1,
      favorite_button: 1,
      gallery_preview: 1,
      genre_chips: 1,
      image_gallery: 1,
      play_button: 1,
      rating_badge: 1,
      series_count_badge: 1,
      similar_grid: 1,
      synopsis_section: 1,
      tmdb_link: 1,
      trailer_link: 1,
      year_badge: 1
    ]

  # Mount for /browse/series/:id (global provider)
  def mount(%{"id" => series_id}, _session, socket)
      when not is_map_key(socket.assigns, :provider) do
    user_id = socket.assigns.current_scope.user.id
    provider = Detail.global_provider()

    if provider do
      mount_with_provider(socket, provider, series_id, user_id, :browse)
    else
      {:ok,
       socket
       |> put_flash(:error, "Catálogo não disponível")
       |> push_navigate(to: ~p"/providers")}
    end
  end

  # Mount for /providers/:provider_id/series/:id (user provider)
  def mount(%{"provider_id" => provider_id, "id" => series_id}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    provider = Detail.playable_provider(user_id, provider_id)

    if provider do
      mount_with_provider(socket, provider, series_id, user_id, :provider)
    else
      {:ok,
       socket
       |> put_flash(:error, "Provedor não encontrado")
       |> push_navigate(to: ~p"/")}
    end
  end

  defp mount_with_provider(socket, provider, series_id, user_id, mode) do
    {:ok, series} = Detail.get_series_with_sync!(series_id)
    mount_series_found(socket, provider, series, user_id, mode)
  rescue
    Ecto.NoResultsError -> mount_series_not_found(socket, mode, provider)
  end

  defp mount_series_not_found(socket, mode, provider) do
    {:ok,
     socket
     |> put_flash(:error, "Série não encontrada")
     |> push_navigate(to: back_path(mode, provider))}
  end

  defp mount_series_found(socket, provider, series, user_id, mode) do
    series = Detail.maybe_fetch_series_info(series)
    sorted_seasons = Detail.seasons_with_episodes(series)

    socket =
      socket
      |> assign(page_title: series.title || series.name)
      |> assign(current_path: series_path_for(mode, provider, series))
      |> assign(provider: provider)
      |> assign(
        premium_access: Detail.premium_access?(socket.assigns.current_scope.user, provider)
      )
      |> assign(series: series)
      |> assign(lcp_image: get_backdrop(series) || maybe_proxy(series.cover))
      |> assign(mode: mode)
      |> assign(seasons: sorted_seasons)
      |> assign(expanded_seasons: Detail.initial_expanded(sorted_seasons))
      |> assign(is_favorite: Detail.favorite?(user_id, "series", series.id))
      |> assign(user_id: user_id)
      |> assign(similar_series: Detail.similar_series(series.id))
      |> assign(selected_gallery_image: nil)

    {:ok, socket}
  end

  defp series_path_for(:browse, _provider, series), do: "/browse/series/#{series.id}"

  defp series_path_for(_mode, provider, series),
    do: "/providers/#{provider.id}/series/#{series.id}"

  # ============================================
  # Event Handlers
  # ============================================

  # ThemeToggle hook event (client-side theme management, no server action needed)
  def handle_event("theme_init", _params, socket), do: {:noreply, socket}

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

  def handle_event("view_episode", %{"id" => episode_id}, socket) do
    path =
      episode_path(
        socket.assigns.mode,
        socket.assigns.provider,
        socket.assigns.series.id,
        episode_id
      )

    {:noreply, push_navigate(socket, to: path)}
  end

  def handle_event("play_first_episode", _, socket) do
    case socket.assigns.seasons do
      [first_season | _] when first_season.episodes != [] ->
        [first_episode | _] = Enum.sort_by(first_season.episodes, & &1.episode_num)

        path =
          episode_path(
            socket.assigns.mode,
            socket.assigns.provider,
            socket.assigns.series.id,
            first_episode.id
          )

        {:noreply, push_navigate(socket, to: path)}

      _ ->
        {:noreply, put_flash(socket, :error, "Nenhum episódio disponível")}
    end
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

  def handle_event("open_gallery_image", %{"src" => image}, socket) do
    {:noreply, assign(socket, selected_gallery_image: image)}
  end

  def handle_event("close_gallery_preview", _, socket) do
    {:noreply, assign(socket, selected_gallery_image: nil)}
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> :error
    end
  end

  defp parse_positive_integer(_), do: :error

  # ============================================
  # Render
  # ============================================

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-background">
      <.detail_hero
        image={get_backdrop(@series) || maybe_proxy(@series.cover)}
        alt={@series.name}
        back_path={back_path(@mode, @provider)}
      />
      
    <!-- Content Section -->
      <div class="relative -mt-16 sm:-mt-32 lg:-mt-40 px-3 sm:px-8 lg:px-12 pb-6 sm:pb-12">
        <div class="max-w-7xl mx-auto">
          <div class="flex flex-col lg:flex-row gap-3 sm:gap-6 lg:gap-8">
            <!-- Poster -->
            <div class="flex-shrink-0 w-24 sm:w-48 lg:w-72 mx-auto lg:mx-0">
              <div class="aspect-[2/3] rounded-lg sm:rounded-xl overflow-hidden shadow-2xl ring-1 ring-white/10">
                <img
                  :if={@series.cover}
                  src={ImageProxy.proxy(@series.cover)}
                  alt={@series.name}
                  class="w-full h-full object-cover"
                  loading="lazy"
                  decoding="async"
                />
                <div
                  :if={!@series.cover}
                  class="w-full h-full bg-surface flex items-center justify-center"
                >
                  <.icon name="hero-tv" class="size-12 sm:size-20 text-text-secondary/30" />
                </div>
              </div>
            </div>
            
    <!-- Info -->
            <div class="flex-1 space-y-2 sm:space-y-4 lg:space-y-6 text-center lg:text-left">
              <.detail_title
                title={@series.title || @series.name}
                subtitle={alternate_title(@series)}
                tagline={@series.tagline}
              />

              <div :if={@mode == :browse and not @premium_access} data-premium-badge>
                <.premium_badge />
              </div>
              
    <!-- Meta Tags -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-1.5 sm:gap-2">
                <.content_rating_badge rating={@series.content_rating} />
                <.rating_badge rating={@series.rating} />
                <.year_badge year={@series.year} />
                <.series_count_badge seasons={@seasons} />
              </div>
              
    <!-- Genres -->
              <.genre_chips genres={@series.genres} />
              
    <!-- Action Buttons -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-2 sm:gap-3 pt-2">
                <.play_button event="play_first_episode" label="Assistir" />

                <StreamixWeb.WatchPartyComponents.create_party_button
                  :if={Enum.any?(@seasons, fn s -> s.episodes != [] end)}
                  content_type="episode"
                  content_id={Enum.find_value(@seasons, fn s -> List.first(s.episodes) end).id}
                />

                <.favorite_button favorite?={@is_favorite} />
                <.trailer_link youtube_id={@series.youtube_trailer} />
                <.tmdb_link type="tv" tmdb_id={@series.tmdb_id} />
              </div>

              <.premium_cta_banner
                :if={@mode == :browse and not @premium_access}
                id="series-detail-premium-cta"
                current_scope={@current_scope}
              />
              
    <!-- Synopsis -->
              <.synopsis_section text={@series.plot} />
              
    <!-- Details Grid -->
              <.credits_grid content={@series} director_label="Criado por" />
            </div>
          </div>
          
    <!-- Image Gallery -->
          <.image_gallery
            images={if Series.has_images?(@series), do: Series.image_urls(@series), else: []}
            alt="Imagem da série"
          />
          
    <!-- Similar Series -->
          <.similar_grid
            items={@similar_series}
            kind={:series}
            mode={@mode}
            provider={@provider}
            title="Séries Similares"
          />
          
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
              <.detail_season_accordion
                :for={season <- @seasons}
                season={season}
                expanded={MapSet.member?(@expanded_seasons, season.id)}
              />
            </div>
          </div>
        </div>
      </div>
      <.gallery_preview image={@selected_gallery_image} alt="Imagem da série" />
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp back_path(:browse, _provider), do: ~p"/browse/series"
  defp back_path(:provider, provider), do: ~p"/providers/#{provider.id}/series"

  defp episode_path(:browse, _provider, series_id, episode_id),
    do: ~p"/browse/series/#{series_id}/episode/#{episode_id}"

  defp episode_path(:provider, provider, series_id, episode_id),
    do: ~p"/providers/#{provider.id}/series/#{series_id}/episode/#{episode_id}"

  defp alternate_title(%{title: title, name: name}) when is_binary(title) and is_binary(name) do
    if title != name, do: name
  end

  defp alternate_title(_), do: nil

  defp get_backdrop(%Series{} = series) do
    case Series.backdrop_urls(series) do
      [url | _] -> ImageProxy.proxy(url)
      _ -> nil
    end
  end

  defp get_backdrop(_), do: nil

  defp maybe_proxy(nil), do: nil
  defp maybe_proxy(url) when is_binary(url), do: ImageProxy.proxy(url)
end
