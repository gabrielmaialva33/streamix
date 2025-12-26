defmodule StreamixWeb.Content.SeriesDetailLive do
  @moduledoc """
  LiveView for displaying series details with seasons and episodes.

  Features:
  - Series hero banner with metadata
  - Season accordion with episodes
  - Episode playback
  - Favorites management
  """
  use StreamixWeb, :live_view

  alias Streamix.Iptv

  import StreamixWeb.CoreComponents, only: [icon: 1]

  @doc false
  def mount(%{"provider_id" => provider_id, "id" => series_id}, _session, socket) do
    user = socket.assigns[:current_scope] && socket.assigns.current_scope.user
    user_id = if user, do: user.id, else: nil
    provider = get_accessible_provider(user_id, provider_id)

    mount_with_provider(socket, provider, series_id, provider_id, user_id)
  end

  defp mount_with_provider(socket, nil, _series_id, _provider_id, _user_id) do
    {:ok,
     socket
     |> put_flash(:error, "Provedor não encontrado")
     |> push_navigate(to: ~p"/")}
  end

  defp mount_with_provider(socket, provider, series_id, provider_id, user_id) do
    case Iptv.get_series_with_seasons(series_id) do
      nil -> mount_series_not_found(socket)
      series -> mount_series_found(socket, provider, series, provider_id, user_id)
    end
  end

  defp mount_series_not_found(socket) do
    {:ok,
     socket
     |> put_flash(:error, "Série não encontrada")
     |> push_navigate(to: ~p"/")}
  end

  defp mount_series_found(socket, provider, series, provider_id, user_id) do
    is_favorite = if user_id, do: Iptv.is_favorite?(user_id, "series", series.id), else: false

    socket =
      socket
      |> assign(page_title: series.title || series.name)
      |> assign(current_path: "/providers/#{provider_id}/series/#{series.id}")
      |> assign(provider: provider)
      |> assign(series: series)
      |> assign(seasons: series.seasons || [])
      |> assign(expanded_seasons: MapSet.new())
      |> assign(is_favorite: is_favorite)
      |> assign(user_id: user_id)

    {:ok, socket}
  end

  defp get_accessible_provider(nil, provider_id), do: Iptv.get_public_provider(provider_id)

  defp get_accessible_provider(user_id, provider_id),
    do: Iptv.get_playable_provider(user_id, provider_id)

  # ============================================
  # Event Handlers
  # ============================================

  @doc false
  def handle_event("toggle_season", %{"id" => season_id}, socket) do
    season_id = String.to_integer(season_id)
    expanded = socket.assigns.expanded_seasons

    expanded =
      if MapSet.member?(expanded, season_id) do
        MapSet.delete(expanded, season_id)
      else
        MapSet.put(expanded, season_id)
      end

    {:noreply, assign(socket, expanded_seasons: expanded)}
  end

  def handle_event("play_episode", %{"id" => episode_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/watch/episode/#{episode_id}")}
  end

  def handle_event("play_first_episode", _, socket) do
    # Find the first episode of the first season
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

  @doc false
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <.back_link provider_id={@provider.id} />

      <.series_hero series={@series} is_favorite={@is_favorite} />

      <.seasons_section
        seasons={@seasons}
        expanded_seasons={@expanded_seasons}
      />
    </div>
    """
  end

  defp back_link(assigns) do
    ~H"""
    <.link
      navigate={~p"/providers/#{@provider_id}/series"}
      class="inline-flex items-center gap-2 text-base-content/70 hover:text-base-content transition-colors"
    >
      <.icon name="hero-arrow-left" class="size-4" />
      <span>Voltar para Séries</span>
    </.link>
    """
  end

  defp series_hero(assigns) do
    ~H"""
    <div class="relative h-[50vh] min-h-[400px] bg-base-300 rounded-xl overflow-hidden">
      <img
        :if={@series.backdrop || @series.cover}
        src={@series.backdrop || @series.cover}
        alt={@series.name}
        class="w-full h-full object-cover"
      />
      <div class="absolute inset-0 bg-gradient-to-t from-base-100 via-base-100/60 to-transparent" />

      <div class="absolute bottom-0 left-0 right-0 p-8">
        <div class="max-w-3xl space-y-4">
          <h1 class="text-4xl font-bold">{@series.title || @series.name}</h1>

          <div class="flex items-center gap-4 text-sm text-base-content/70">
            <span :if={@series.year}>{@series.year}</span>
            <span :if={@series.rating} class="flex items-center gap-1">
              <.icon name="hero-star-solid" class="size-4 text-warning" />
              {format_rating(@series.rating)}
            </span>
            <span :if={@series.genre}>{@series.genre}</span>
            <span :if={length(@series.seasons || []) > 0}>
              {pluralize(length(@series.seasons), "temporada", "temporadas")}
            </span>
          </div>

          <p :if={@series.plot} class="text-base-content/80 line-clamp-3">
            {@series.plot}
          </p>

          <div class="flex items-center gap-3 pt-2">
            <button
              type="button"
              phx-click="play_first_episode"
              class="btn btn-primary gap-2"
            >
              <.icon name="hero-play-solid" class="size-5" /> Assistir
            </button>

            <button
              type="button"
              phx-click="toggle_favorite"
              class={[
                "btn gap-2",
                @is_favorite && "btn-error",
                !@is_favorite && "btn-ghost"
              ]}
            >
              <.icon
                name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"}
                class="size-5"
              />
              {if @is_favorite, do: "Favoritado", else: "Favoritar"}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp seasons_section(assigns) do
    ~H"""
    <section class="space-y-4">
      <h2 class="text-2xl font-bold">Temporadas</h2>

      <div :if={Enum.empty?(@seasons)} class="text-base-content/60">
        Nenhuma temporada disponível.
      </div>

      <div class="space-y-3">
        <.season_item
          :for={season <- Enum.sort_by(@seasons, & &1.season_number)}
          season={season}
          expanded={MapSet.member?(@expanded_seasons, season.id)}
        />
      </div>
    </section>
    """
  end

  defp season_item(assigns) do
    episode_count = length(assigns.season.episodes || [])
    assigns = assign(assigns, :episode_count, episode_count)

    ~H"""
    <div class="collapse collapse-arrow bg-base-200 rounded-lg">
      <input
        type="checkbox"
        checked={@expanded}
        phx-click="toggle_season"
        phx-value-id={@season.id}
      />
      <div class="collapse-title font-medium flex items-center gap-3">
        <span>Temporada {@season.season_number}</span>
        <span class="badge badge-sm badge-ghost">
          {pluralize(@episode_count, "episódio", "episódios")}
        </span>
      </div>
      <div class="collapse-content">
        <div class="space-y-2 pt-2">
          <.episode_row
            :for={episode <- Enum.sort_by(@season.episodes || [], & &1.episode_num)}
            episode={episode}
          />
        </div>
      </div>
    </div>
    """
  end

  defp episode_row(assigns) do
    ~H"""
    <div
      class="flex gap-4 p-3 bg-base-100 hover:bg-base-300 rounded-lg cursor-pointer transition-all group"
      phx-click="play_episode"
      phx-value-id={@episode.id}
    >
      <div class="relative w-32 sm:w-40 aspect-video flex-shrink-0 bg-base-300 rounded overflow-hidden">
        <img
          :if={@episode.cover}
          src={@episode.cover}
          alt={episode_title(@episode)}
          class="w-full h-full object-cover"
          loading="lazy"
        />
        <div
          :if={!@episode.cover}
          class="w-full h-full flex items-center justify-center text-base-content/30"
        >
          <.icon name="hero-play" class="size-8" />
        </div>

        <div class="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <.icon name="hero-play-solid" class="size-8 text-white" />
        </div>

        <div class="absolute bottom-1 right-1 badge badge-xs badge-ghost">
          E{@episode.episode_num}
        </div>
      </div>

      <div class="flex-1 min-w-0 py-1">
        <h4 class="font-medium text-sm sm:text-base truncate">{episode_title(@episode)}</h4>
        <p :if={@episode.plot} class="text-xs sm:text-sm text-base-content/60 line-clamp-2 mt-1">
          {@episode.plot}
        </p>
        <div class="flex items-center gap-3 mt-2 text-xs text-base-content/50">
          <span :if={@episode.duration}>{format_duration(@episode.duration)}</span>
          <span :if={@episode.rating} class="flex items-center gap-1">
            <.icon name="hero-star-solid" class="size-3 text-warning" />
            {format_rating(@episode.rating)}
          </span>
        </div>
      </div>
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp episode_title(episode) do
    episode.title || "Episódio #{episode.episode_num}"
  end

  defp format_rating(rating) when is_number(rating) do
    Float.round(rating / 2, 1) |> to_string()
  end

  defp format_rating(_), do: nil

  defp format_duration(duration) when is_binary(duration), do: duration

  defp format_duration(duration) when is_integer(duration) do
    hours = div(duration, 60)
    minutes = rem(duration, 60)

    if hours > 0, do: "#{hours}h #{minutes}min", else: "#{minutes}min"
  end

  defp format_duration(_), do: nil

  defp pluralize(1, singular, _plural), do: "1 #{singular}"
  defp pluralize(count, _singular, plural), do: "#{count} #{plural}"
end
