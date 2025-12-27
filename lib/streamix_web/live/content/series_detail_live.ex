defmodule StreamixWeb.Content.SeriesDetailLive do
  @moduledoc """
  LiveView for displaying series details with seasons and episodes.
  Works for both /browse/series/:id (global provider) and /providers/:id/series/:id (user provider).
  """
  use StreamixWeb, :live_view

  alias Streamix.Iptv

  import StreamixWeb.CoreComponents, only: [icon: 1]

  # Mount for /browse/series/:id (global provider)
  def mount(%{"id" => series_id}, _session, socket)
      when not is_map_key(socket.assigns, :provider) do
    user_id = socket.assigns.current_scope.user.id
    provider = Iptv.get_global_provider()

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
    provider = Iptv.get_playable_provider(user_id, provider_id)

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
    {:ok, series} = Iptv.get_series_with_sync!(series_id)
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
    is_favorite = if user_id, do: Iptv.is_favorite?(user_id, "series", series.id), else: false
    sorted_seasons = Enum.sort_by(series.seasons || [], & &1.season_number)

    first_season_id =
      case sorted_seasons do
        [first | _] -> first.id
        _ -> nil
      end

    # Fetch TMDB enrichment if needed
    series = maybe_fetch_series_info(series)

    current_path =
      if mode == :browse,
        do: "/browse/series/#{series.id}",
        else: "/providers/#{provider.id}/series/#{series.id}"

    socket =
      socket
      |> assign(page_title: series.title || series.name)
      |> assign(current_path: current_path)
      |> assign(provider: provider)
      |> assign(series: series)
      |> assign(mode: mode)
      |> assign(seasons: sorted_seasons)
      |> assign(
        expanded_seasons:
          if(first_season_id, do: MapSet.new([first_season_id]), else: MapSet.new())
      )
      |> assign(is_favorite: is_favorite)
      |> assign(user_id: user_id)

    {:ok, socket}
  end

  defp maybe_fetch_series_info(series) do
    if needs_detailed_info?(series) do
      case Iptv.fetch_series_info(series) do
        {:ok, updated_series} -> updated_series
        {:error, _reason} -> series
      end
    else
      series
    end
  end

  defp needs_detailed_info?(series) do
    # Refetch if missing basic info OR if missing new extended metadata
    missing_basic = is_nil(series.plot) and is_nil(series.cast) and is_nil(series.director)
    missing_extended = is_nil(series.content_rating) and is_nil(series.tagline)

    missing_basic or missing_extended
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
    {:noreply, push_navigate(socket, to: ~p"/watch/episode/#{episode_id}")}
  end

  def handle_event("play_first_episode", _, socket) do
    case socket.assigns.seasons do
      [first_season | _] when first_season.episodes != [] ->
        [first_episode | _] = Enum.sort_by(first_season.episodes, & &1.episode_num)
        {:noreply, push_navigate(socket, to: ~p"/watch/episode/#{first_episode.id}")}

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
      <!-- Hero Section -->
      <div class="relative h-[50vh] sm:h-[60vh] min-h-[400px]">
        <div class="absolute inset-0">
          <img
            :if={get_backdrop(@series) || @series.cover}
            src={get_backdrop(@series) || @series.cover}
            alt={@series.name}
            class="w-full h-full object-cover"
          />
          <div
            :if={!get_backdrop(@series) && !@series.cover}
            class="w-full h-full bg-gradient-to-br from-neutral-800 to-neutral-900"
          />
        </div>

        <div class="absolute inset-0 bg-gradient-to-t from-background via-background/60 to-transparent" />
        <div class="absolute inset-0 bg-gradient-to-r from-background via-background/30 to-transparent" />

        <!-- Back Button -->
        <div class="absolute top-6 left-6 z-10">
          <.link
            navigate={back_path(@mode, @provider)}
            class="inline-flex items-center gap-2 px-4 py-2 bg-black/40 backdrop-blur-sm text-white/90 hover:text-white hover:bg-black/60 rounded-full transition-all text-sm font-medium"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Voltar
          </.link>
        </div>

        <!-- Play Button Overlay -->
        <button
          type="button"
          phx-click="play_first_episode"
          class="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 w-20 h-20 bg-white/20 backdrop-blur-sm hover:bg-white/30 rounded-full flex items-center justify-center transition-all group"
        >
          <.icon name="hero-play-solid" class="size-10 text-white ml-1 group-hover:scale-110 transition-transform" />
        </button>
      </div>

      <!-- Content Section -->
      <div class="relative -mt-32 sm:-mt-40 px-4 sm:px-8 lg:px-12 pb-12">
        <div class="max-w-7xl mx-auto">
          <div class="flex flex-col lg:flex-row gap-8">
            <!-- Poster -->
            <div class="flex-shrink-0 w-48 sm:w-56 lg:w-72 mx-auto lg:mx-0">
              <div class="aspect-[2/3] rounded-xl overflow-hidden shadow-2xl ring-1 ring-white/10">
                <img
                  :if={@series.cover}
                  src={@series.cover}
                  alt={@series.name}
                  class="w-full h-full object-cover"
                />
                <div
                  :if={!@series.cover}
                  class="w-full h-full bg-surface flex items-center justify-center"
                >
                  <.icon name="hero-tv" class="size-20 text-text-secondary/30" />
                </div>
              </div>
            </div>

            <!-- Info -->
            <div class="flex-1 space-y-6 text-center lg:text-left">
              <!-- Title -->
              <div class="space-y-2">
                <h1 class="text-3xl sm:text-4xl lg:text-5xl font-bold text-text-primary leading-tight">
                  {@series.title || @series.name}
                </h1>
                <p :if={@series.title && @series.name && @series.title != @series.name} class="text-lg text-text-secondary">
                  {@series.name}
                </p>
                <!-- Tagline -->
                <p :if={@series.tagline && @series.tagline != ""} class="text-lg italic text-text-secondary/80">
                  "{@series.tagline}"
                </p>
              </div>

              <!-- Meta Tags -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-2">
                <!-- Content Rating -->
                <span
                  :if={@series.content_rating}
                  class={[
                    "inline-flex items-center justify-center min-w-[42px] h-8 px-2.5 rounded-md text-xs font-bold",
                    content_rating_class(@series.content_rating)
                  ]}
                  title="Classificação Indicativa"
                >
                  {@series.content_rating}
                </span>
                <span
                  :if={@series.rating}
                  class="inline-flex items-center gap-1 h-8 px-2.5 bg-yellow-500/20 text-yellow-400 rounded-md text-sm font-semibold"
                >
                  <.icon name="hero-star-solid" class="size-3.5" />
                  {format_rating(@series.rating)}
                </span>
                <span :if={@series.year} class="inline-flex items-center h-8 px-2.5 bg-surface text-text-primary rounded-md text-sm font-medium">
                  {@series.year}
                </span>
                <span class="inline-flex items-center gap-1 h-8 px-2.5 bg-surface text-text-secondary rounded-md text-sm">
                  <.icon name="hero-tv" class="size-3.5" />
                  {length(@seasons)} temp · {@series.episode_count || 0} eps
                </span>
              </div>

              <!-- Genres -->
              <div :if={@series.genre} class="flex flex-wrap items-center justify-center lg:justify-start gap-2">
                <span
                  :for={genre <- split_genres(@series.genre)}
                  class="px-3 py-1 bg-white/5 text-text-secondary rounded-full text-sm border border-white/10 hover:border-white/20 transition-colors"
                >
                  {genre}
                </span>
              </div>

              <!-- Action Buttons -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-3 pt-2">
                <button
                  type="button"
                  phx-click="play_first_episode"
                  class="inline-flex items-center gap-2 px-8 py-3.5 bg-brand text-white font-bold rounded-lg hover:bg-brand-hover transition-colors shadow-lg shadow-brand/30"
                >
                  <.icon name="hero-play-solid" class="size-5" /> Assistir
                </button>

                <button
                  type="button"
                  phx-click="toggle_favorite"
                  class={[
                    "inline-flex items-center justify-center w-12 h-12 rounded-lg border-2 transition-all",
                    @is_favorite && "bg-red-600 border-red-600 text-white",
                    !@is_favorite && "border-border text-text-secondary hover:border-text-secondary hover:text-text-primary bg-surface"
                  ]}
                  title={if @is_favorite, do: "Remover dos favoritos", else: "Adicionar aos favoritos"}
                >
                  <.icon
                    name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"}
                    class="size-5"
                  />
                </button>

                <a
                  :if={@series.youtube_trailer}
                  href={trailer_url(@series.youtube_trailer)}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="inline-flex items-center gap-2 px-5 py-3 bg-surface border border-border text-text-primary font-semibold rounded-lg hover:bg-surface-hover transition-colors"
                >
                  <.icon name="hero-play-circle" class="size-5 text-red-500" /> Trailer
                </a>

                <a
                  :if={@series.tmdb_id}
                  href={"https://www.themoviedb.org/tv/#{@series.tmdb_id}"}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="inline-flex items-center gap-2 px-4 py-3 bg-surface border border-border text-text-secondary rounded-lg hover:text-text-primary hover:bg-surface-hover transition-colors text-sm"
                  title="Ver no The Movie Database"
                >
                  <svg class="size-4" viewBox="0 0 24 24" fill="currentColor">
                    <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/>
                  </svg>
                  TMDB
                </a>
              </div>

              <!-- Synopsis -->
              <div :if={@series.plot} class="pt-4">
                <h3 class="text-lg font-semibold text-text-primary mb-3">Sinopse</h3>
                <p class="text-text-secondary text-base leading-relaxed">
                  {@series.plot}
                </p>
              </div>

              <!-- Details Grid -->
              <div :if={@series.director || @series.cast} class="grid sm:grid-cols-2 gap-6 pt-4">
                <div :if={@series.director} class="space-y-2">
                  <h4 class="text-sm font-semibold text-text-secondary uppercase tracking-wide">Criado por</h4>
                  <p class="text-text-primary">{@series.director}</p>
                </div>

                <div :if={@series.cast} class="space-y-2">
                  <h4 class="text-sm font-semibold text-text-secondary uppercase tracking-wide">Elenco</h4>
                  <p class="text-text-primary">{truncate_cast(@series.cast)}</p>
                </div>
              </div>
            </div>
          </div>

          <!-- Image Gallery -->
          <div :if={@series.images && @series.images != []} class="mt-12">
            <h3 class="text-xl font-semibold text-text-primary mb-4">Galeria</h3>
            <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 gap-3">
              <div
                :for={image <- @series.images}
                class="aspect-video rounded-lg overflow-hidden bg-surface-hover cursor-pointer hover:ring-2 hover:ring-brand transition-all group"
              >
                <img
                  src={image}
                  alt="Imagem da série"
                  class="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300"
                  loading="lazy"
                />
              </div>
            </div>
          </div>

          <!-- Episodes Section -->
          <div class="mt-12 space-y-6">
            <h2 class="text-2xl font-bold text-text-primary">Episódios</h2>

            <div :if={Enum.empty?(@seasons)} class="text-center py-12">
              <.icon name="hero-film" class="size-16 mx-auto mb-4 text-text-secondary/20" />
              <p class="text-text-secondary">Nenhum episódio disponível</p>
            </div>

            <div class="space-y-4">
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
    <div class="bg-surface rounded-xl overflow-hidden border border-border">
      <button
        type="button"
        phx-click="toggle_season"
        phx-value-id={@season.id}
        class="w-full flex items-center justify-between px-6 py-4 hover:bg-surface-hover transition-colors"
      >
        <div class="flex items-center gap-4">
          <span class="text-lg font-semibold text-text-primary">Temporada {@season.season_number}</span>
          <span class="text-sm text-text-secondary">{length(@episodes)} episódios</span>
        </div>
        <.icon
          name="hero-chevron-down"
          class={["size-5 text-text-secondary transition-transform duration-200", @expanded && "rotate-180"]}
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
      class="flex gap-4 p-4 hover:bg-surface-hover cursor-pointer transition-colors group"
      phx-click="play_episode"
      phx-value-id={@episode.id}
    >
      <div class="flex-shrink-0 w-8 text-center">
        <span class="text-2xl font-bold text-text-secondary/30">{@episode.episode_num}</span>
      </div>

      <div class="relative flex-shrink-0 w-36 aspect-video bg-surface-hover rounded-lg overflow-hidden">
        <img
          :if={@episode.cover}
          src={@episode.cover}
          alt={episode_title(@episode)}
          class="w-full h-full object-cover"
          loading="lazy"
        />
        <div
          :if={!@episode.cover}
          class="w-full h-full flex items-center justify-center bg-surface"
        >
          <.icon name="hero-play-circle" class="size-10 text-text-secondary/30" />
        </div>

        <div class="absolute inset-0 bg-black/50 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <div class="w-10 h-10 rounded-full bg-white flex items-center justify-center">
            <.icon name="hero-play-solid" class="size-5 text-black ml-0.5" />
          </div>
        </div>
      </div>

      <div class="flex-1 min-w-0">
        <h4 class="font-medium text-text-primary group-hover:text-brand truncate">
          {episode_title(@episode)}
        </h4>
        <p :if={@episode.plot} class="text-sm text-text-secondary line-clamp-2 mt-1">
          {@episode.plot}
        </p>
        <span :if={@episode.duration} class="text-xs text-text-secondary/60 mt-2 block">
          {@episode.duration}
        </span>
      </div>
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp back_path(:browse, _provider), do: ~p"/browse/series"
  defp back_path(:provider, provider), do: ~p"/providers/#{provider.id}/series"

  defp episode_title(episode), do: "Episódio #{episode.episode_num}"

  defp format_rating(%Decimal{} = rating) do
    rating
    |> Decimal.div(2)
    |> Decimal.round(1)
    |> Decimal.to_string()
  end

  defp format_rating(rating) when is_number(rating) do
    Float.round(rating / 2, 1) |> to_string()
  end

  defp format_rating(_), do: nil

  defp get_backdrop(%{backdrop_path: [url | _]}) when is_binary(url), do: url
  defp get_backdrop(_), do: nil

  defp trailer_url(youtube_id) when is_binary(youtube_id) do
    if String.contains?(youtube_id, "youtube.com") or String.contains?(youtube_id, "youtu.be") do
      youtube_id
    else
      "https://www.youtube.com/watch?v=#{youtube_id}"
    end
  end

  defp trailer_url(_), do: nil

  defp split_genres(nil), do: []

  defp split_genres(genre) when is_binary(genre) do
    genre
    |> String.split(~r/[,\/]/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(5)
  end

  defp truncate_cast(nil), do: nil

  defp truncate_cast(cast) when is_binary(cast) do
    cast
    |> String.split(",")
    |> Enum.take(5)
    |> Enum.map(&String.trim/1)
    |> Enum.join(", ")
  end

  # Content rating color classes based on Brazilian/US ratings
  defp content_rating_class(rating) when is_binary(rating) do
    rating_upper = String.upcase(rating)

    cond do
      # Livre / General (green)
      rating_upper in ["L", "G", "TV-G", "TV-Y", "TV-Y7"] ->
        "bg-green-500/20 text-green-400"

      # 10 anos / PG (blue)
      rating_upper in ["10", "PG", "TV-PG"] ->
        "bg-blue-500/20 text-blue-400"

      # 12 anos / PG-13 (yellow)
      rating_upper in ["12", "PG-13", "TV-14"] ->
        "bg-yellow-500/20 text-yellow-400"

      # 14 anos (orange)
      rating_upper in ["14"] ->
        "bg-orange-500/20 text-orange-400"

      # 16 anos (red-orange)
      rating_upper in ["16", "R", "TV-MA"] ->
        "bg-red-400/20 text-red-400"

      # 18 anos / NC-17 (dark red)
      rating_upper in ["18", "NC-17"] ->
        "bg-red-600/20 text-red-500"

      # Default
      true ->
        "bg-surface text-text-secondary"
    end
  end

  defp content_rating_class(_), do: "bg-surface text-text-secondary"
end
