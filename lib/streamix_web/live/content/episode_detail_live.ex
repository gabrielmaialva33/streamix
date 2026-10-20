defmodule StreamixWeb.Content.EpisodeDetailLive do
  @moduledoc """
  LiveView for displaying episode details before playback.
  Works for both /browse/series/:series_id/episode/:id (global provider)
  and /providers/:provider_id/series/:series_id/episode/:id (user provider).
  """
  use StreamixWeb, :live_view

  alias StreamixWeb.Content.Detail
  alias StreamixWeb.Content.DisplayTitle
  alias StreamixWeb.Content.HelperComponents
  alias StreamixWeb.Content.SourceBadges
  alias StreamixWeb.PlayerHelpers

  import StreamixWeb.CoreComponents, only: [icon: 1]
  import StreamixWeb.Helpers.Params, only: [parse_positive_integer: 1]
  import StreamixWeb.SourcePickerComponents, only: [source_picker: 1]

  import StreamixWeb.Content.DetailComponents.Actions, only: [favorite_button: 1]

  import StreamixWeb.Content.DetailComponents.Badges,
    only: [
      content_rating_badge: 1,
      date_badge: 1,
      duration_badge: 1,
      extension_badge: 1,
      rating_badge: 1
    ]

  import StreamixWeb.Content.DetailComponents,
    only: [
      detail_hero: 1,
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
    return_to = safe_return_path(params["return_to"])

    Detail.with_provider(socket, :provider, params, fn provider ->
      mount_with_provider(socket, provider, series_id, episode_id, user_id, :provider, return_to)
    end)
  end

  # Mount for /browse/series/:series_id/episode/:id (global provider)
  def mount(%{"series_id" => series_id, "id" => episode_id} = params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    return_to = safe_return_path(params["return_to"])

    Detail.with_provider(socket, :browse, %{}, fn provider ->
      mount_with_provider(socket, provider, series_id, episode_id, user_id, :browse, return_to)
    end)
  end

  defp mount_with_provider(socket, provider, series_id, episode_id, user_id, mode, return_to) do
    episode = Detail.get_episode_with_context!(episode_id)
    series = episode.season.series

    # Verify episode belongs to the series
    if to_string(series.id) != series_id do
      {:ok,
       socket
       |> put_flash(:error, "Episódio não encontrado")
       |> push_navigate(to: back_path(return_to, mode, provider, series_id))}
    else
      mount_episode_found(socket, provider, episode, series, user_id, mode, return_to)
    end
  rescue
    Ecto.NoResultsError ->
      {:ok,
       socket
       |> put_flash(:error, "Episódio não encontrado")
       |> redirect(to: ~p"/")}
  end

  defp mount_episode_found(socket, provider, episode, series, user_id, mode, return_to) do
    user = socket.assigns.current_scope.user
    is_favorite = Detail.favorite?(user_id, "series", series.id)

    # Enrich episode with TMDB data if needed
    episode = Detail.maybe_fetch_episode_info(episode)

    maybe_prewarm(socket, episode, user_id)

    navigation = Detail.episode_navigation(episode)

    {episode_sources, source_options} =
      build_episode_sources(episode, series, user)

    current_path =
      mode
      |> base_episode_path(provider, series.id, episode.id)
      |> with_return_to(return_to)

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
      |> assign(return_to: return_to)
      |> assign(is_favorite: is_favorite)
      |> assign(user_id: user_id)
      |> assign(episode_sources: episode_sources)
      |> assign(source_options: source_options)
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

  def handle_event("play_episode", _, socket) do
    {:noreply, redirect(socket, to: ~p"/watch/episode/#{socket.assigns.episode.id}")}
  end

  def handle_event("select_source", %{"id" => raw_id}, socket) do
    with {:ok, target_id} <- parse_positive_integer(raw_id),
         %{episode_id: episode_id, series_id: series_id} <-
           Enum.find(socket.assigns.episode_sources, &(&1.episode_id == target_id)) do
      target_path =
        "/browse/series/#{series_id}/episode/#{episode_id}"
        |> with_return_to(socket.assigns.return_to)

      {:noreply, push_navigate(socket, to: target_path)}
    else
      _ -> {:noreply, socket}
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

  # ============================================
  # Render
  # ============================================

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-background">
      <.detail_hero
        image={get_episode_image(@episode) || get_series_backdrop(@series)}
        alt={episode_title(@episode, @series)}
        back_path={back_path(@return_to, @mode, @provider, @series.id)}
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
                  navigate={all_episodes_path(@series.id)}
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

              <!-- Source Picker -->
              <div class="pt-1 text-left">
                <.source_picker
                  id="episode-source-picker"
                  options={@source_options}
                  selected={@episode.id}
                  event="select_source"
                />
              </div>

              <!-- Action Buttons -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-2 sm:gap-3 pt-2">
                <StreamixWeb.Content.DetailComponents.Actions.play_button
                  event="play_episode"
                  label="Assistir"
                />

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
          <.episode_footer_navigation
            mode={@mode}
            provider={@provider}
            series={@series}
            return_to={@return_to}
            prev_episode={@prev_episode}
            next_episode={@next_episode}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :mode, :atom, required: true
  attr :provider, :map, required: true
  attr :series, :map, required: true
  attr :return_to, :string, default: nil
  attr :prev_episode, :map, default: nil
  attr :next_episode, :map, default: nil

  defp episode_footer_navigation(assigns) do
    ~H"""
    <div class="mt-6 sm:mt-10 pt-6 sm:pt-8 border-t border-border">
      <div class="flex items-center justify-between gap-2 sm:gap-4">
        <div class="flex-1 min-w-0">
          <.link
            :if={@prev_episode}
            id="episode-prev-link"
            navigate={
              base_episode_path(@mode, @provider, @series.id, @prev_episode.id)
              |> with_return_to(@return_to)
            }
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

        <.link
          id="episode-all-episodes-link"
          navigate={all_episodes_path(@series.id)}
          class="hidden sm:inline-flex items-center gap-2 px-4 sm:px-5 py-2.5 sm:py-3 bg-surface border border-border text-text-secondary rounded-lg hover:text-text-primary hover:bg-surface-hover transition-colors text-xs sm:text-sm"
        >
          <.icon name="hero-list-bullet" class="size-4" /> Todos os Episódios
        </.link>

        <div class="flex-1 flex justify-end min-w-0">
          <.link
            :if={@next_episode}
            id="episode-next-link"
            navigate={
              base_episode_path(@mode, @provider, @series.id, @next_episode.id)
              |> with_return_to(@return_to)
            }
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
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp build_episode_sources(episode, series, user) do
    user_id = user && user.id
    season_number = episode.season.season_number
    episode_num = episode.episode_num

    series_by_episode_id =
      series
      |> Streamix.Playback.list_series_variants(user_id, limit: 24)
      |> Enum.reduce(%{episode.id => series.id}, fn candidate_series, acc ->
        case matching_episode(candidate_series, season_number, episode_num) do
          %{id: ep_id} -> Map.put_new(acc, ep_id, candidate_series.id)
          _ -> acc
        end
      end)

    candidates =
      "episode"
      |> PlayerHelpers.failover_sources(episode, user_id)
      |> Enum.uniq_by(& &1.provider_id)

    providers =
      candidates
      |> Enum.map(& &1.provider)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)

    statuses = Streamix.Providers.provider_health_statuses(providers)

    episode_sources =
      Enum.map(candidates, fn candidate ->
        %{
          episode_id: candidate.id,
          series_id: Map.get(series_by_episode_id, candidate.id, series.id),
          provider: candidate.provider,
          content: candidate.content
        }
      end)

    options =
      candidates
      |> Enum.with_index()
      |> Enum.map(fn {candidate, index} ->
        provider = candidate.provider
        provider_id = candidate.provider_id || (provider && provider.id)

        %{
          id: candidate.id,
          label: provider_name(provider, provider_id),
          badges: SourceBadges.badges(candidate.content),
          note: nil,
          recommended: index == 0,
          unstable: Map.get(statuses, provider_id) == :degraded,
          locked: not Detail.premium_access?(user, provider)
        }
      end)

    {episode_sources, options}
  end

  defp matching_episode(series, season_number, episode_number) do
    with seasons when is_list(seasons) <- Map.get(series, :seasons),
         season when not is_nil(season) <-
           Enum.find(seasons, &(Map.get(&1, :season_number) == season_number)),
         episodes when is_list(episodes) <- Map.get(season, :episodes) do
      Enum.find(episodes, &(Map.get(&1, :episode_num) == episode_number))
    else
      _ -> nil
    end
  end

  defp provider_name(%{name: name}, _provider_id) when is_binary(name) and name != "", do: name

  defp provider_name(_provider, provider_id) when is_integer(provider_id),
    do: "Provedor #{provider_id}"

  defp provider_name(_provider, _provider_id), do: "Provedor"

  defp all_episodes_path(series_id), do: "/browse/series/#{series_id}?source=#{series_id}"

  defp back_path(return_to, _mode, _provider, _series_id) when is_binary(return_to), do: return_to
  defp back_path(_return_to, :browse, _provider, series_id), do: all_episodes_path(series_id)

  defp back_path(_return_to, :provider, provider, series_id),
    do: ~p"/providers/#{provider.id}/series/#{series_id}"

  defp base_episode_path(:browse, _provider, series_id, episode_id),
    do: ~p"/browse/series/#{series_id}/episode/#{episode_id}"

  defp base_episode_path(:provider, provider, series_id, episode_id),
    do: ~p"/providers/#{provider.id}/series/#{series_id}/episode/#{episode_id}"

  defp with_return_to(path, return_to) when is_binary(return_to) do
    separator = if String.contains?(path, "?"), do: "&", else: "?"
    path <> separator <> "return_to=" <> URI.encode_www_form(return_to)
  end

  defp with_return_to(path, _return_to), do: path

  defp safe_return_path(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") do
      path
    end
  end

  defp safe_return_path(_), do: nil

  defp episode_title(episode, series) do
    base = series.title || series.name
    "S#{episode.season.season_number}E#{episode.episode_num} - #{base}"
  end

  # Title before name. `name` holds the raw filename for almost every episode in
  # the catalog, so this page was showing
  # "Vingadores.Unidos.da.Marvel.S01E23.1080p.DSNP.WEB-DL...mkv" as the label.
  defp episode_display_title(episode),
    do: episode |> HelperComponents.episode_title() |> DisplayTitle.episode()

  defp get_episode_image(episode) do
    episode.still_path || episode.cover
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp get_series_backdrop(series) do
    case Streamix.Catalog.backdrop_urls(series) do
      [url | _] -> url
      _ -> get_series_backdrop_fallback(series)
    end
  end

  defp get_series_backdrop_fallback(%{cover: cover}) when is_binary(cover), do: cover
  defp get_series_backdrop_fallback(_), do: nil
end
