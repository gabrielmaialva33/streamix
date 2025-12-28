defmodule StreamixWeb.Content.EpisodeDetailLive do
  @moduledoc """
  LiveView for displaying episode details before playback.
  Works for both /browse/series/:series_id/episode/:id (global provider)
  and /providers/:provider_id/series/:series_id/episode/:id (user provider).
  """
  use StreamixWeb, :live_view

  alias Streamix.Iptv

  import StreamixWeb.CoreComponents, only: [icon: 1]

  # Mount for /browse/series/:series_id/episode/:id (global provider)
  def mount(%{"series_id" => series_id, "id" => episode_id}, _session, socket)
      when not is_map_key(socket.assigns, :provider) do
    user_id = socket.assigns.current_scope.user.id
    provider = Iptv.get_global_provider()

    if provider do
      mount_with_provider(socket, provider, series_id, episode_id, user_id, :browse)
    else
      {:ok,
       socket
       |> put_flash(:error, "Catálogo não disponível")
       |> push_navigate(to: ~p"/providers")}
    end
  end

  # Mount for /providers/:provider_id/series/:series_id/episode/:id (user provider)
  def mount(
        %{"provider_id" => provider_id, "series_id" => series_id, "id" => episode_id},
        _session,
        socket
      ) do
    user_id = socket.assigns.current_scope.user.id
    provider = Iptv.get_playable_provider(user_id, provider_id)

    if provider do
      mount_with_provider(socket, provider, series_id, episode_id, user_id, :provider)
    else
      {:ok,
       socket
       |> put_flash(:error, "Provedor não encontrado")
       |> push_navigate(to: ~p"/")}
    end
  end

  defp mount_with_provider(socket, provider, series_id, episode_id, user_id, mode) do
    episode = Iptv.get_episode_with_context!(episode_id)
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
       |> push_navigate(to: ~p"/")}
  end

  defp mount_episode_found(socket, provider, episode, series, user_id, mode) do
    is_favorite = if user_id, do: Iptv.is_favorite?(user_id, "series", series.id), else: false

    # Enrich episode with TMDB data if needed
    episode = maybe_fetch_episode_info(episode)

    # Get adjacent episodes for navigation
    season = episode.season
    episodes = Iptv.list_season_episodes(season.id)
    current_index = Enum.find_index(episodes, &(&1.id == episode.id))

    prev_episode = if current_index && current_index > 0, do: Enum.at(episodes, current_index - 1)

    next_episode =
      if current_index && current_index < length(episodes) - 1,
        do: Enum.at(episodes, current_index + 1)

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
      |> assign(season: season)
      |> assign(series: series)
      |> assign(mode: mode)
      |> assign(is_favorite: is_favorite)
      |> assign(user_id: user_id)
      |> assign(prev_episode: prev_episode)
      |> assign(next_episode: next_episode)
      |> assign(total_episodes: length(episodes))

    {:ok, socket}
  end

  defp maybe_fetch_episode_info(episode) do
    case Iptv.fetch_episode_info(episode) do
      {:ok, updated_episode} -> updated_episode
      {:error, _reason} -> episode
    end
  end

  # ============================================
  # Event Handlers
  # ============================================

  def handle_event("play_episode", _, socket) do
    {:noreply, push_navigate(socket, to: ~p"/watch/episode/#{socket.assigns.episode.id}")}
  end

  def handle_event("toggle_favorite", _, socket) do
    case socket.assigns.user_id do
      nil ->
        {:noreply, put_flash(socket, :info, "Faça login para adicionar favoritos")}

      user_id ->
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
  end

  # ============================================
  # Render
  # ============================================

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-background">
      <!-- Hero Section with Episode Thumbnail -->
      <div class="relative h-[35vh] sm:h-[45vh] lg:h-[50vh] min-h-[240px] sm:min-h-[300px]">
        <div class="absolute inset-0">
          <img
            :if={get_episode_image(@episode) || get_series_backdrop(@series)}
            src={get_episode_image(@episode) || get_series_backdrop(@series)}
            alt={episode_title(@episode, @series)}
            class="w-full h-full object-cover"
          />
          <div
            :if={!get_episode_image(@episode) && !get_series_backdrop(@series)}
            class="w-full h-full bg-gradient-to-br from-neutral-800 to-neutral-900"
          />
        </div>

        <div class="absolute inset-0 bg-gradient-to-t from-background via-background/60 to-transparent" />
        <div class="absolute inset-0 bg-gradient-to-r from-background via-background/30 to-transparent" />

    <!-- Back Button -->
        <div class="absolute top-4 left-4 sm:top-6 sm:left-6 z-10">
          <.link
            navigate={back_path(@mode, @provider, @series.id)}
            class="inline-flex items-center gap-1.5 sm:gap-2 px-3 sm:px-4 py-1.5 sm:py-2 bg-black/40 backdrop-blur-sm text-white/90 hover:text-white hover:bg-black/60 rounded-full transition-all text-xs sm:text-sm font-medium max-w-[200px] sm:max-w-none"
          >
            <.icon name="hero-arrow-left" class="size-3.5 sm:size-4 flex-shrink-0" />
            <span class="truncate">Voltar</span>
          </.link>
        </div>
      </div>

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
                <span
                  :if={@series.content_rating}
                  class={[
                    "inline-flex items-center justify-center min-w-[36px] sm:min-w-[42px] h-6 sm:h-8 px-2 sm:px-2.5 rounded-md text-[10px] sm:text-xs font-bold",
                    content_rating_class(@series.content_rating)
                  ]}
                  title="Classificação Indicativa"
                >
                  {@series.content_rating}
                </span>
                <span
                  :if={@episode.rating}
                  class="inline-flex items-center gap-1 h-6 sm:h-8 px-2 sm:px-2.5 bg-yellow-500/20 text-yellow-400 rounded-md text-xs sm:text-sm font-medium"
                >
                  <.icon name="hero-star-solid" class="size-3 sm:size-3.5" />{format_rating(@episode.rating)}
                </span>
                <span
                  :if={@episode.air_date}
                  class="inline-flex items-center gap-1 h-6 sm:h-8 px-2 sm:px-2.5 bg-surface text-text-secondary rounded-md text-xs sm:text-sm"
                >
                  <.icon name="hero-calendar" class="size-3 sm:size-3.5" />{format_date(@episode.air_date)}
                </span>
                <span
                  :if={@episode.duration}
                  class="inline-flex items-center gap-1 h-6 sm:h-8 px-2 sm:px-2.5 bg-surface text-text-secondary rounded-md text-xs sm:text-sm"
                >
                  <.icon name="hero-clock" class="size-3 sm:size-3.5" />{@episode.duration}
                </span>
                <span
                  :if={@episode.container_extension}
                  class="inline-flex items-center h-6 sm:h-8 px-2 sm:px-2.5 bg-brand/20 text-brand rounded-md uppercase text-[10px] sm:text-xs font-bold"
                >
                  {@episode.container_extension}
                </span>
              </div>
              
    <!-- Action Buttons -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-2 sm:gap-3 pt-2">
                <button
                  type="button"
                  phx-click="play_episode"
                  class="inline-flex items-center justify-center gap-2 w-full sm:w-auto px-6 sm:px-8 py-3 sm:py-3.5 bg-brand text-white font-bold rounded-lg hover:bg-brand-hover transition-colors shadow-lg shadow-brand/30 text-sm sm:text-base"
                >
                  <.icon name="hero-play-solid" class="size-4 sm:size-5" /> Assistir Episódio
                </button>

                <button
                  type="button"
                  phx-click="toggle_favorite"
                  class={[
                    "inline-flex items-center justify-center w-10 h-10 sm:w-12 sm:h-12 rounded-lg border-2 transition-all",
                    @is_favorite && "bg-red-600 border-red-600 text-white",
                    !@is_favorite &&
                      "border-border text-text-secondary hover:border-text-secondary hover:text-text-primary bg-surface"
                  ]}
                  title={
                    if @is_favorite, do: "Série nos favoritos", else: "Adicionar série aos favoritos"
                  }
                >
                  <.icon
                    name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"}
                    class="size-4 sm:size-5"
                  />
                </button>
              </div>

    <!-- Synopsis -->
              <div :if={@episode.plot && @episode.plot != ""} class="pt-2 sm:pt-4">
                <h3 class="text-base sm:text-lg font-semibold text-text-primary mb-2 sm:mb-3">Sinopse</h3>
                <p class="text-text-secondary text-sm sm:text-base leading-relaxed">
                  {@episode.plot}
                </p>
              </div>

    <!-- Series Synopsis (if no episode synopsis) -->
              <div :if={(!@episode.plot || @episode.plot == "") && @series.plot} class="pt-2 sm:pt-4">
                <h3 class="text-base sm:text-lg font-semibold text-text-primary mb-2 sm:mb-3">Sobre a Série</h3>
                <p class="text-text-secondary text-sm sm:text-base leading-relaxed line-clamp-4">
                  {@series.plot}
                </p>
              </div>
            </div>
          </div>
          
    <!-- Episode Navigation -->
          <div class="mt-6 sm:mt-10 pt-6 sm:pt-8 border-t border-border">
            <div class="flex items-center justify-between gap-2 sm:gap-4">
              <!-- Previous Episode -->
              <div class="flex-1 min-w-0">
                <.link
                  :if={@prev_episode}
                  navigate={episode_path(@mode, @provider, @series.id, @prev_episode.id)}
                  class="inline-flex items-center gap-2 sm:gap-3 p-2.5 sm:p-4 rounded-lg sm:rounded-xl bg-surface hover:bg-surface-hover transition-colors group"
                >
                  <.icon
                    name="hero-chevron-left"
                    class="size-4 sm:size-5 text-text-secondary group-hover:text-text-primary flex-shrink-0"
                  />
                  <div class="text-left min-w-0">
                    <p class="text-[10px] sm:text-xs text-text-secondary uppercase tracking-wide">
                      Anterior
                    </p>
                    <p class="text-xs sm:text-sm font-medium text-text-primary truncate">
                      Ep. {@prev_episode.episode_num}
                    </p>
                  </div>
                </.link>
              </div>

    <!-- Back to Series -->
              <.link
                navigate={series_path(@mode, @provider, @series.id)}
                class="hidden sm:inline-flex items-center gap-2 px-4 sm:px-5 py-2.5 sm:py-3 bg-surface border border-border text-text-secondary rounded-lg hover:text-text-primary hover:bg-surface-hover transition-colors text-xs sm:text-sm"
              >
                <.icon name="hero-list-bullet" class="size-4" /> Todos os Episódios
              </.link>

    <!-- Next Episode -->
              <div class="flex-1 flex justify-end min-w-0">
                <.link
                  :if={@next_episode}
                  navigate={episode_path(@mode, @provider, @series.id, @next_episode.id)}
                  class="inline-flex items-center gap-2 sm:gap-3 p-2.5 sm:p-4 rounded-lg sm:rounded-xl bg-surface hover:bg-surface-hover transition-colors group"
                >
                  <div class="text-right min-w-0">
                    <p class="text-[10px] sm:text-xs text-text-secondary uppercase tracking-wide">
                      Próximo
                    </p>
                    <p class="text-xs sm:text-sm font-medium text-text-primary truncate">
                      Ep. {@next_episode.episode_num}
                    </p>
                  </div>
                  <.icon
                    name="hero-chevron-right"
                    class="size-4 sm:size-5 text-text-secondary group-hover:text-text-primary flex-shrink-0"
                  />
                </.link>
              </div>
            </div>
          </div>
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

  defp episode_path(:browse, _provider, series_id, episode_id),
    do: ~p"/browse/series/#{series_id}/episode/#{episode_id}"

  defp episode_path(:provider, provider, series_id, episode_id),
    do: ~p"/providers/#{provider.id}/series/#{series_id}/episode/#{episode_id}"

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

  defp format_rating(nil), do: nil

  defp format_rating(rating) do
    # Convert from TMDB 0-10 scale to display format (1 decimal)
    value = Decimal.to_float(rating)
    :erlang.float_to_binary(value, decimals: 1)
  end

  defp format_date(nil), do: nil

  defp format_date(date) do
    Calendar.strftime(date, "%d/%m/%Y")
  end

  defp get_series_backdrop(%{backdrop_path: [url | _]}) when is_binary(url), do: url
  defp get_series_backdrop(%{cover: cover}) when is_binary(cover), do: cover
  defp get_series_backdrop(_), do: nil

  # Content rating color classes
  defp content_rating_class(rating) when is_binary(rating) do
    rating_upper = String.upcase(rating)

    cond do
      rating_upper in ["L", "G", "TV-G", "TV-Y", "TV-Y7"] ->
        "bg-green-500/20 text-green-400"

      rating_upper in ["10", "PG", "TV-PG"] ->
        "bg-blue-500/20 text-blue-400"

      rating_upper in ["12", "PG-13", "TV-14"] ->
        "bg-yellow-500/20 text-yellow-400"

      rating_upper in ["14"] ->
        "bg-orange-500/20 text-orange-400"

      rating_upper in ["16", "R", "TV-MA"] ->
        "bg-red-400/20 text-red-400"

      rating_upper in ["18", "NC-17"] ->
        "bg-red-600/20 text-red-500"

      true ->
        "bg-surface text-text-secondary"
    end
  end

  defp content_rating_class(_), do: "bg-surface text-text-secondary"
end
