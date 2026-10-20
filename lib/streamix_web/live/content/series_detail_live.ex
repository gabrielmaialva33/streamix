defmodule StreamixWeb.Content.SeriesDetailLive do
  @moduledoc """
  LiveView for displaying series details with seasons and episodes.
  Works for both /browse/series/:id (global provider) and /providers/:id/series/:id (user provider).
  """
  use StreamixWeb, :live_view
  alias StreamixWeb.Content.Detail
  alias StreamixWeb.Content.SeriesSources
  alias StreamixWeb.LiveSessionNavigation

  import StreamixWeb.SourcePickerComponents
  import StreamixWeb.App.Premium
  import StreamixWeb.CoreComponents, only: [icon: 1]
  import StreamixWeb.Helpers.Params, only: [parse_positive_integer: 1]

  import StreamixWeb.Content.DetailComponents.Actions,
    only: [favorite_button: 1, play_button: 1, tmdb_link: 1, trailer_link: 1]

  import StreamixWeb.Content.DetailComponents.Badges,
    only: [
      content_rating_badge: 1,
      rating_badge: 1,
      series_count_badge: 1,
      year_badge: 1
    ]

  import StreamixWeb.Content.DetailComponents,
    only: [
      credits_grid: 1,
      detail_hero: 1,
      detail_season_accordion: 1,
      detail_title: 1,
      gallery_preview: 1,
      genre_chips: 1,
      image_gallery: 1,
      similar_grid: 1,
      synopsis_section: 1
    ]

  # Mount for /providers/:provider_id/series/:id (user provider). Must
  # come first: the browse clause's pattern also matches these params.
  def mount(%{"provider_id" => _, "id" => series_id} = params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    return_to = safe_return_path(params["return_to"])
    provider_filter = provider_query_param(params["provider"])

    Detail.with_provider(socket, :provider, params, fn provider ->
      mount_with_provider(
        socket,
        provider,
        series_id,
        user_id,
        :provider,
        return_to,
        provider_filter
      )
    end)
  end

  # Mount for /browse/series/:id (global provider)
  def mount(%{"id" => series_id} = params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    return_to = safe_return_path(params["return_to"])
    provider_filter = provider_query_param(params["provider"])

    Detail.with_provider(socket, :browse, %{}, fn provider ->
      mount_with_provider(
        socket,
        provider,
        series_id,
        user_id,
        :browse,
        return_to,
        provider_filter
      )
    end)
  end

  defp mount_with_provider(socket, provider, series_id, user_id, mode, return_to, provider_filter) do
    series =
      case parse_positive_integer(series_id) do
        {:ok, series_id} -> Detail.get_playable_series(user_id, series_id)
        :error -> nil
      end

    case series do
      nil ->
        mount_series_not_found(socket, mode, provider, return_to)

      series ->
        series = Detail.get_series_with_sync!(series.id)
        mount_series_found(socket, provider, series, user_id, mode, return_to, provider_filter)
    end
  end

  defp mount_series_not_found(socket, mode, provider, return_to) do
    target = back_path(return_to, mode, provider)

    {:ok,
     socket
     |> put_flash(:error, "Série não encontrada")
     |> LiveSessionNavigation.navigate("/browse/series", target)}
  end

  defp mount_series_found(socket, provider, series, user_id, mode, return_to, provider_filter) do
    preferred_provider_id = preferred_provider_id(provider_filter, mode, provider)

    series_sources =
      SeriesSources.list(series, user_id, preferred_provider_id: preferred_provider_id)

    progress = Streamix.Library.latest_series_progress(user_id, Enum.map(series_sources, & &1.id))
    selected_series = default_source(series_sources, progress, series)
    selected_seasons = Detail.seasons_with_episodes(selected_series)

    socket =
      socket
      |> assign(page_title: series.title || series.name)
      |> assign(
        current_path:
          series_path_for(mode, provider, series) |> with_provider_filter(provider_filter)
      )
      |> assign(provider: provider)
      |> assign(
        premium_access: Detail.premium_access?(socket.assigns.current_scope.user, provider)
      )
      |> assign(series: series)
      |> assign(lcp_image: Detail.hero_image(series, series.cover))
      |> assign(mode: mode)
      |> assign(return_to: return_to)
      |> assign(provider_filter: provider_filter)
      |> assign(preferred_provider_id: preferred_provider_id)
      |> assign(source_progress: progress)
      |> assign(
        source_options: SeriesSources.options(series_sources, socket.assigns.current_scope.user)
      )
      |> assign(selected_series: selected_series)
      |> assign(selected_seasons: selected_seasons)
      |> assign(series_sources: series_sources)
      |> assign(expanded_seasons: Detail.initial_expanded(selected_seasons))
      |> assign(is_favorite: Detail.favorite?(user_id, "series", series.id))
      |> assign(user_id: user_id)
      |> assign(similar_series: [])
      |> assign(selected_gallery_image: nil)
      |> start_detail_tasks(series)

    {:ok, socket}
  end

  def handle_params(params, _uri, %{assigns: %{series_sources: sources}} = socket) do
    selected =
      Enum.find(sources, &(Integer.to_string(&1.id) == params["source"])) ||
        default_source(sources, socket.assigns.source_progress, socket.assigns.series)

    {:noreply, select_source(socket, selected)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp select_source(socket, selected) do
    seasons = Detail.seasons_with_episodes(selected)

    open_numbers =
      socket.assigns.selected_seasons
      |> Enum.filter(&MapSet.member?(socket.assigns.expanded_seasons, &1.id))
      |> Enum.map(& &1.season_number)

    expanded = seasons |> Enum.filter(&(&1.season_number in open_numbers)) |> Enum.map(& &1.id)
    expanded = if expanded == [], do: Detail.initial_expanded(seasons), else: MapSet.new(expanded)
    current_path = source_path(socket.assigns, selected.id)
    episodes = Enum.flat_map(seasons, & &1.episodes)
    progress = Map.get(socket.assigns.source_progress, selected.id)

    resume =
      if progress && !progress.completed, do: Enum.find(episodes, &(&1.id == progress.episode_id))

    playable = resume || first_episode(seasons)

    socket
    |> assign(selected_series: selected, selected_seasons: seasons, expanded_seasons: expanded)
    |> assign(
      current_path: current_path,
      playable_episode: playable,
      resuming: not is_nil(resume)
    )
    |> assign(
      premium_access: Detail.premium_access?(socket.assigns.current_scope.user, selected.provider)
    )
    |> assign(
      episode_paths:
        Map.new(episodes, &{&1.id, selected_episode_path(selected, &1, current_path)})
    )
    |> stream(:seasons, seasons, reset: true)
  end

  defp default_source(sources, progress, fallback) do
    latest =
      Enum.max_by(
        progress,
        fn {_id, entry} -> {DateTime.to_unix(entry.watched_at), entry.progress_id} end,
        fn -> nil end
      )

    case latest do
      {id, _} -> Enum.find(sources, &(&1.id == id)) || List.first(sources) || fallback
      nil -> List.first(sources) || fallback
    end
  end

  defp source_path(assigns, source_id) do
    query = %{"source" => source_id}

    query =
      if assigns.provider_filter,
        do: Map.put(query, "provider", assigns.provider_filter),
        else: query

    query = if assigns.return_to, do: Map.put(query, "return_to", assigns.return_to), else: query

    series_path_for(assigns.mode, assigns.provider, assigns.series) <>
      "?" <> URI.encode_query(query)
  end

  def handle_async({:series_enrichment, series_id}, {:ok, series}, socket)
      when series_id == socket.assigns.series.id do
    {:noreply,
     socket
     |> assign(page_title: series.title || series.name)
     |> assign(series: series)
     |> assign(lcp_image: Detail.hero_image(series, series.cover))}
  end

  def handle_async({:series_recommendations, series_id}, {:ok, series}, socket)
      when series_id == socket.assigns.series.id do
    {:noreply, assign(socket, similar_series: series)}
  end

  def handle_async({task, _series_id}, {:ok, _result}, socket)
      when task in [:series_enrichment, :series_recommendations],
      do: {:noreply, socket}

  def handle_async({task, _series_id}, {:exit, _reason}, socket)
      when task in [:series_enrichment, :series_recommendations],
      do: {:noreply, socket}

  defp series_path_for(:browse, _provider, series), do: "/browse/series/#{series.id}"

  defp series_path_for(_mode, provider, series),
    do: "/providers/#{provider.id}/series/#{series.id}"

  defp start_detail_tasks(socket, series) do
    if connected?(socket) do
      socket
      |> start_async({:series_enrichment, series.id}, fn ->
        Detail.maybe_fetch_series_info(series)
      end)
      |> start_async({:series_recommendations, series.id}, fn ->
        Detail.similar_series(series.id)
      end)
    else
      socket
    end
  end

  # ============================================
  # Event Handlers
  # ============================================

  def handle_event("select_source", %{"id" => id}, socket) do
    selected =
      Enum.find(socket.assigns.series_sources, &(Integer.to_string(&1.id) == id)) ||
        default_source(
          socket.assigns.series_sources,
          socket.assigns.source_progress,
          socket.assigns.series
        )

    {:noreply, push_patch(socket, to: source_path(socket.assigns, selected.id))}
  end

  def handle_event("toggle_season", %{"id" => season_id}, socket) do
    case parse_positive_integer(season_id) do
      {:ok, season_id} ->
        expanded = socket.assigns.expanded_seasons

        expanded =
          if MapSet.member?(expanded, season_id),
            do: MapSet.delete(expanded, season_id),
            else: MapSet.put(expanded, season_id)

        {:noreply,
         socket
         |> assign(expanded_seasons: expanded)
         |> stream(:seasons, socket.assigns.selected_seasons, reset: true)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("view_episode", %{"id" => episode_id}, socket) do
    case parse_positive_integer(episode_id) do
      {:ok, id} ->
        case Map.get(socket.assigns.episode_paths, id) do
          nil -> {:noreply, socket}
          path -> {:noreply, push_navigate(socket, to: path)}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("play_first_episode", _, socket) do
    case socket.assigns.playable_episode do
      nil ->
        {:noreply, put_flash(socket, :error, "Nenhum episódio disponível")}

      episode ->
        {:noreply,
         push_navigate(socket, to: Map.fetch!(socket.assigns.episode_paths, episode.id))}
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

  # ============================================
  # Render
  # ============================================

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-background">
      <.detail_hero
        image={Detail.hero_image(@series, @series.cover)}
        alt={@series.name}
        back_path={back_path(@return_to, @mode, @provider)}
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

              <div :if={not @premium_access} data-premium-badge>
                <.premium_badge />
              </div>

              <!-- Meta Tags -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-1.5 sm:gap-2">
                <.content_rating_badge rating={@series.content_rating} />
                <.rating_badge rating={@series.rating} />
                <.year_badge year={@series.year} />
                <.series_count_badge seasons={@selected_seasons} />
              </div>

              <!-- Genres -->
              <.genre_chips genres={@series.genres} />

              <!-- Action Buttons -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-2 sm:gap-3 pt-2">
                <.play_button
                  event="play_first_episode"
                  label={if @resuming, do: "Continuar", else: "Assistir"}
                />
                <StreamixWeb.WatchPartyComponents.create_party_button
                  :if={@playable_episode}
                  content_type="episode"
                  content_id={@playable_episode.id}
                />

                <.favorite_button favorite?={@is_favorite} />
                <.trailer_link youtube_id={@series.youtube_trailer} />
                <.tmdb_link type="tv" tmdb_id={@series.tmdb_id} />
              </div>

              <a
                :if={length(@source_options) > 1}
                id="series-source-summary"
                href="#episodes"
                class="inline-flex min-h-11 items-center gap-1.5 text-sm text-text-secondary hover:text-text-primary"
              >
                <.icon name="hero-server-stack" class="size-4" />
                <span>
                  Assistindo de
                  <span class="font-semibold text-text-primary">
                    {provider_name(@selected_series)}
                  </span>
                </span>
                <span class="text-brand">· Trocar fonte</span>
              </a>

              <.premium_cta_banner
                :if={not @premium_access}
                id="series-detail-premium-cta"
                current_scope={@current_scope}
              />

              <%!-- Synopsis --%>
              <.synopsis_section text={@series.plot} />
            </div>
          </div>

          <!-- Episodes Section -->
          <div id="episodes" class="mt-8 sm:mt-12 space-y-4 sm:space-y-6">
            <h2 class="text-xl sm:text-2xl font-bold text-text-primary">Episódios</h2>

            <.source_picker
              id="series-source-picker"
              options={@source_options}
              selected={@selected_series.id}
              event="select_source"
            />
            <div :if={Enum.empty?(@selected_seasons)} class="text-center py-8 sm:py-12">
              <.icon
                name="hero-film"
                class="size-12 sm:size-16 mx-auto mb-3 sm:mb-4 text-text-secondary/20"
              />
              <p class="text-text-secondary text-sm sm:text-base">Nenhum episódio disponível</p>
            </div>

            <div id="series-seasons" phx-update="stream" class="space-y-3 sm:space-y-4">
              <div :for={{dom_id, season} <- @streams.seasons} id={dom_id}>
                <.detail_season_accordion
                  season={season}
                  expanded={MapSet.member?(@expanded_seasons, season.id)}
                  episode_paths={@episode_paths}
                />
              </div>
            </div>
          </div>
          <.credits_grid content={@series} director_label="Criado por" />

          <!-- Image Gallery -->
          <.image_gallery
            images={
              if Streamix.Catalog.has_images?(@series),
                do: Streamix.Catalog.image_urls(@series),
                else: []
            }
            alt="Imagem da série"
          />

          <!-- Similar Series -->
          <.similar_grid
            items={@similar_series}
            kind={:series}
            mode={@mode}
            provider={@provider}
            return_to={@current_path}
            title="Séries Similares"
          />
        </div>
      </div>
      <.gallery_preview image={@selected_gallery_image} alt="Imagem da série" />
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp back_path(return_to, _mode, _provider) when is_binary(return_to), do: return_to
  defp back_path(_return_to, :browse, _provider), do: ~p"/browse/series"
  defp back_path(_return_to, :provider, provider), do: ~p"/providers/#{provider.id}/series"

  defp selected_episode_path(%{provider_id: provider_id, id: series_id}, episode, return_to),
    do:
      ~p"/providers/#{provider_id}/series/#{series_id}/episode/#{episode.id}"
      |> with_return_to(return_to)

  defp with_return_to(path, return_to) when is_binary(return_to) do
    separator = if String.contains?(path, "?"), do: "&", else: "?"
    path <> separator <> "return_to=" <> URI.encode_www_form(return_to)
  end

  defp with_provider_filter(path, nil), do: path
  defp with_provider_filter(path, provider_filter), do: path <> "?provider=" <> provider_filter

  defp safe_return_path(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") do
      path
    end
  end

  defp safe_return_path(_), do: nil

  defp provider_query_param(value) when value in ["all", "global"], do: value

  defp provider_query_param(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> Integer.to_string(id)
      _ -> nil
    end
  end

  defp provider_query_param(_), do: nil

  defp preferred_provider_id(provider_filter, _mode, _provider) when is_binary(provider_filter) do
    case Integer.parse(provider_filter) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp preferred_provider_id(_provider_filter, :provider, %{id: id}), do: id
  defp preferred_provider_id(_provider_filter, _mode, _provider), do: nil

  defp first_episode([first_season | _]) when first_season.episodes != [] do
    first_season.episodes
    |> Enum.sort_by(& &1.episode_num)
    |> List.first()
  end

  defp first_episode(_), do: nil

  defp provider_name(%{provider: %{name: name}}) when is_binary(name) and name != "", do: name
  defp provider_name(%{provider_id: provider_id}), do: "Provedor #{provider_id}"

  defp alternate_title(%{title: title, name: name}) when is_binary(title) and is_binary(name) do
    if title != name, do: name
  end

  defp alternate_title(_), do: nil
end
