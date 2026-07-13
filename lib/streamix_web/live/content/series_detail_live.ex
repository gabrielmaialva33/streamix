defmodule StreamixWeb.Content.SeriesDetailLive do
  @moduledoc """
  LiveView for displaying series details with seasons and episodes.
  Works for both /browse/series/:id (global provider) and /providers/:id/series/:id (user provider).
  """
  use StreamixWeb, :live_view

  alias Streamix.Iptv.Series
  alias StreamixWeb.Content.Detail

  import StreamixWeb.CoreComponents, only: [icon: 1]
  import StreamixWeb.Helpers.Params, only: [parse_positive_integer: 1]

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
        {:ok, series} = Detail.get_series_with_sync!(series.id)
        mount_series_found(socket, provider, series, user_id, mode, return_to, provider_filter)
    end
  end

  defp mount_series_not_found(socket, mode, provider, return_to) do
    {:ok,
     socket
     |> put_flash(:error, "Série não encontrada")
     |> push_navigate(to: back_path(return_to, mode, provider))}
  end

  defp mount_series_found(socket, provider, series, user_id, mode, return_to, provider_filter) do
    series = Detail.maybe_fetch_series_info(series)
    sorted_seasons = Detail.seasons_with_episodes(series)
    preferred_provider_id = preferred_provider_id(provider_filter, mode, provider)

    series_sources =
      series
      |> Detail.series_variants(user_id)
      |> ensure_current_series(series)
      |> sort_series_sources(series.id, preferred_provider_id)
      |> dedupe_series_sources()

    selected_series = selected_series_source(series_sources, series)
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
      |> assign(seasons: sorted_seasons)
      |> assign(selected_series: selected_series)
      |> assign(selected_seasons: selected_seasons)
      |> assign(series_sources: series_sources)
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
    case socket.assigns.selected_seasons do
      [first_season | _] when first_season.episodes != [] ->
        [first_episode | _] = Enum.sort_by(first_season.episodes, & &1.episode_num)

        {:noreply,
         push_navigate(
           socket,
           to:
             selected_episode_path(
               socket.assigns.selected_series,
               first_episode,
               socket.assigns.current_path
             )
         )}

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

              <%!-- Synopsis --%>
              <.synopsis_section text={@series.plot} />

              <.series_sources
                sources={@series_sources}
                current_series_id={@series.id}
                selected_series_id={@selected_series.id}
                current_path={@current_path}
              />
              
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

  defp back_path(return_to, _mode, _provider) when is_binary(return_to), do: return_to
  defp back_path(_return_to, :browse, _provider), do: ~p"/browse/series"
  defp back_path(_return_to, :provider, provider), do: ~p"/providers/#{provider.id}/series"

  defp episode_path(:browse, _provider, series_id, episode_id),
    do: ~p"/browse/series/#{series_id}/episode/#{episode_id}"

  defp episode_path(:provider, provider, series_id, episode_id),
    do: ~p"/providers/#{provider.id}/series/#{series_id}/episode/#{episode_id}"

  defp selected_episode_path(%{provider_id: provider_id, id: series_id}, episode, return_to),
    do:
      ~p"/providers/#{provider_id}/series/#{series_id}/episode/#{episode.id}"
      |> with_return_to(return_to)

  defp provider_series_path(%{provider_id: provider_id}), do: ~p"/providers/#{provider_id}/series"

  defp provider_category_path(%{provider_id: provider_id}, %{id: category_id}),
    do: ~p"/providers/#{provider_id}/series?category=#{category_id}"

  defp with_return_to(path, return_to) when is_binary(return_to) do
    separator = if String.contains?(path, "?"), do: "&", else: "?"
    path <> separator <> "return_to=" <> URI.encode_www_form(return_to)
  end

  defp with_return_to(path, _return_to), do: path

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

  defp ensure_current_series(sources, series) do
    cond do
      Enum.any?(sources, &(&1.id == series.id)) -> sources
      Detail.seasons_with_episodes(series) != [] -> [series | sources]
      true -> sources
    end
  end

  defp sort_series_sources(sources, current_series_id, preferred_provider_id) do
    Enum.sort_by(sources, fn source ->
      {
        provider_rank(source.provider_id, preferred_provider_id),
        current_rank(source.id, current_series_id),
        provider_name(source),
        source.title || source.name || ""
      }
    end)
  end

  defp selected_series_source([source | _], _series), do: source
  defp selected_series_source([], series), do: series

  defp dedupe_series_sources(sources), do: Enum.uniq_by(sources, & &1.provider_id)

  defp provider_rank(provider_id, provider_id) when not is_nil(provider_id), do: 0
  defp provider_rank(_provider_id, _preferred_provider_id), do: 1

  defp current_rank(current_series_id, current_series_id), do: 0
  defp current_rank(_source_id, _current_series_id), do: 1

  defp first_episode([first_season | _]) when first_season.episodes != [] do
    first_season.episodes
    |> Enum.sort_by(& &1.episode_num)
    |> List.first()
  end

  defp first_episode(_), do: nil

  defp provider_name(%{provider: %{name: name}}) when is_binary(name) and name != "", do: name
  defp provider_name(%{provider_id: provider_id}), do: "Provider #{provider_id}"

  defp source_categories(%{categories: categories}) when is_list(categories) do
    categories
    |> Enum.reject(& &1.is_adult)
    |> Enum.take(4)
  end

  defp source_categories(_), do: []

  defp source_counts(series) do
    seasons = Detail.seasons_with_episodes(series)

    episode_count =
      seasons
      |> Enum.flat_map(& &1.episodes)
      |> length()

    {length(seasons), episode_count}
  end

  defp series_sources(assigns) do
    ~H"""
    <section :if={length(@sources) > 0} class="space-y-3 pt-2 pb-16 md:pb-2 text-left">
      <div class="flex items-center justify-between gap-3">
        <h2 class="text-base sm:text-lg font-semibold text-text-primary">
          {if length(@sources) == 1, do: "Fonte disponível", else: "Fontes disponíveis"}
        </h2>
        <span class="text-xs text-text-muted">
          {length(@sources)} {if length(@sources) == 1, do: "provider", else: "providers"}
        </span>
      </div>

      <div class="grid gap-2">
        <article
          :for={source <- @sources}
          class={[
            "rounded-lg border bg-surface/80 p-3 sm:p-4 transition-colors",
            source.id == @selected_series_id && "border-brand/60 ring-1 ring-brand/30",
            source.id != @selected_series_id && "border-border hover:border-brand/40"
          ]}
        >
          <% {season_count, episode_count} = source_counts(source) %>
          <% playable_episode = first_episode(Detail.seasons_with_episodes(source)) %>

          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div class="min-w-0 space-y-2">
              <div class="flex flex-wrap items-center gap-2">
                <span class="truncate text-sm font-semibold text-text-primary">
                  {source.title || source.name}
                </span>
                <span
                  :if={source.id == @selected_series_id}
                  class="rounded bg-brand/15 px-1.5 py-0.5 text-[10px] font-bold uppercase text-brand"
                >
                  Selecionada
                </span>
                <span
                  :if={source.id == @current_series_id and source.id != @selected_series_id}
                  class="rounded bg-brand/15 px-1.5 py-0.5 text-[10px] font-bold uppercase text-brand"
                >
                  Atual
                </span>
              </div>

              <div class="flex flex-wrap items-center gap-1.5 text-xs text-text-secondary">
                <span class="inline-flex items-center gap-1 rounded bg-surface-hover px-2 py-1">
                  <.icon name="hero-server-stack" class="size-3.5" />
                  {provider_name(source)}
                </span>
                <span class="rounded bg-surface-hover px-2 py-1">
                  {season_count} temporadas
                </span>
                <span class="rounded bg-surface-hover px-2 py-1">
                  {episode_count} episódios
                </span>
                <span
                  :if={source.dub_available}
                  class="rounded bg-brand/10 px-2 py-1 font-medium text-brand"
                >
                  DUB
                </span>
              </div>

              <div class="flex flex-wrap gap-1.5">
                <.link
                  :for={category <- source_categories(source)}
                  navigate={provider_category_path(source, category)}
                  class="inline-flex min-h-9 items-center rounded bg-white/5 px-2 py-1 text-[11px] text-text-muted hover:bg-brand/10 hover:text-text-primary"
                >
                  {category.name}
                </.link>
              </div>
            </div>

            <div class="flex w-full flex-wrap items-center gap-2 sm:w-auto sm:shrink-0">
              <.link
                :if={playable_episode}
                navigate={selected_episode_path(source, playable_episode, @current_path)}
                class="inline-flex min-h-11 flex-1 items-center justify-center gap-1.5 rounded-md bg-brand px-3 py-2 text-xs font-semibold text-white hover:bg-brand-hover sm:flex-none"
              >
                <.icon name="hero-play-solid" class="size-3.5" /> Assistir
              </.link>
              <.link
                navigate={provider_series_path(source)}
                class="inline-flex min-h-11 flex-1 items-center justify-center gap-1.5 rounded-md border border-border bg-surface-hover px-3 py-2 text-xs font-semibold text-text-primary hover:border-brand/60 sm:flex-none"
              >
                <.icon name="hero-funnel" class="size-3.5" /> Catálogo
              </.link>
              <.link
                :if={source.id != @current_series_id}
                navigate={
                  ~p"/providers/#{source.provider_id}/series/#{source.id}?return_to=#{@current_path}"
                }
                class="inline-flex min-h-11 flex-1 items-center justify-center gap-1.5 rounded-md border border-border px-3 py-2 text-xs font-semibold text-text-secondary hover:border-brand/60 hover:text-text-primary sm:flex-none"
              >
                <.icon name="hero-information-circle" class="size-3.5" /> Detalhes
              </.link>
            </div>
          </div>
        </article>
      </div>
    </section>
    """
  end

  defp alternate_title(%{title: title, name: name}) when is_binary(title) and is_binary(name) do
    if title != name, do: name
  end

  defp alternate_title(_), do: nil
end
