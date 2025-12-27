defmodule StreamixWeb.Content.SeriesDetailLive do
  @moduledoc """
  LiveView for displaying series details with seasons and episodes.
  """
  use StreamixWeb, :live_view

  alias Streamix.Iptv

  import StreamixWeb.CoreComponents, only: [icon: 1]

  def mount(%{"provider_id" => provider_id, "id" => series_id}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    provider = Iptv.get_playable_provider(user_id, provider_id)

    mount_with_provider(socket, provider, series_id, provider_id, user_id)
  end

  defp mount_with_provider(socket, nil, _series_id, _provider_id, _user_id) do
    {:ok,
     socket
     |> put_flash(:error, "Provedor não encontrado")
     |> push_navigate(to: ~p"/")}
  end

  defp mount_with_provider(socket, provider, series_id, provider_id, user_id) do
    {:ok, series} = Iptv.get_series_with_sync!(series_id)
    mount_series_found(socket, provider, series, provider_id, user_id)
  rescue
    Ecto.NoResultsError -> mount_series_not_found(socket)
  end

  defp mount_series_not_found(socket) do
    {:ok,
     socket
     |> put_flash(:error, "Série não encontrada")
     |> push_navigate(to: ~p"/")}
  end

  defp mount_series_found(socket, provider, series, provider_id, user_id) do
    is_favorite = if user_id, do: Iptv.is_favorite?(user_id, "series", series.id), else: false
    sorted_seasons = Enum.sort_by(series.seasons || [], & &1.season_number)

    first_season_id =
      case sorted_seasons do
        [first | _] -> first.id
        _ -> nil
      end

    socket =
      socket
      |> assign(page_title: series.title || series.name)
      |> assign(current_path: "/providers/#{provider_id}/series/#{series.id}")
      |> assign(provider: provider)
      |> assign(series: series)
      |> assign(seasons: sorted_seasons)
      |> assign(expanded_seasons: if(first_season_id, do: MapSet.new([first_season_id]), else: MapSet.new()))
      |> assign(is_favorite: is_favorite)
      |> assign(user_id: user_id)

    {:ok, socket}
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
    <div class="min-h-screen">
      <%!-- Hero Section --%>
      <div class="relative h-[60vh] min-h-[500px]">
        <%!-- Background Image --%>
        <div class="absolute inset-0">
          <img
            :if={get_backdrop(@series) || @series.cover}
            src={get_backdrop(@series) || @series.cover}
            alt={@series.name}
            class="w-full h-full object-cover"
          />
          <div :if={!get_backdrop(@series) && !@series.cover} class="w-full h-full bg-gradient-to-br from-neutral-800 to-neutral-900" />
        </div>

        <%!-- Gradient Overlay --%>
        <div class="absolute inset-0 bg-gradient-to-t from-background via-background/80 to-background/20" />
        <div class="absolute inset-0 bg-gradient-to-r from-background/90 via-background/40 to-transparent" />

        <%!-- Content --%>
        <div class="absolute bottom-0 left-0 right-0 p-6 sm:p-10">
          <div class="max-w-4xl space-y-5">
            <%!-- Back Link --%>
            <.link
              navigate={~p"/providers/#{@provider.id}/series"}
              class="inline-flex items-center gap-2 text-sm text-white/70 hover:text-white transition-colors"
            >
              <.icon name="hero-arrow-left" class="size-4" />
              Voltar
            </.link>

            <%!-- Title --%>
            <h1 class="text-4xl sm:text-5xl font-bold text-white drop-shadow-2xl">
              {@series.title || @series.name}
            </h1>

            <%!-- Metadata --%>
            <div class="flex flex-wrap items-center gap-3 text-sm">
              <span :if={@series.year} class="text-white/80">{@series.year}</span>
              <span :if={@series.rating} class="flex items-center gap-1 px-2 py-0.5 bg-yellow-500/20 text-yellow-400 rounded">
                <.icon name="hero-star-solid" class="size-4" />
                {format_rating(@series.rating)}
              </span>
              <span :if={@series.genre} class="px-2 py-0.5 bg-white/10 text-white/80 rounded">{@series.genre}</span>
              <span class="text-white/60">
                {length(@series.seasons || [])} temp · {@series.episode_count || 0} eps
              </span>
            </div>

            <%!-- Synopsis --%>
            <p :if={@series.plot} class="text-white/70 text-base leading-relaxed max-w-2xl line-clamp-3">
              {@series.plot}
            </p>

            <%!-- Actions --%>
            <div class="flex items-center gap-4 pt-2">
              <button
                type="button"
                phx-click="play_first_episode"
                class="inline-flex items-center gap-2 px-8 py-3.5 bg-white text-black font-bold rounded hover:bg-white/90 transition-colors"
              >
                <.icon name="hero-play-solid" class="size-6" />
                Assistir
              </button>

              <button
                type="button"
                phx-click="toggle_favorite"
                class={[
                  "inline-flex items-center justify-center w-12 h-12 rounded-full border-2 transition-colors",
                  @is_favorite && "bg-red-600 border-red-600 text-white",
                  !@is_favorite && "border-white/40 text-white hover:border-white"
                ]}
              >
                <.icon name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"} class="size-6" />
              </button>
            </div>
          </div>
        </div>
      </div>

      <%!-- Seasons Section --%>
      <div class="px-6 sm:px-10 py-8 space-y-6">
        <h2 class="text-2xl font-bold text-white">Episódios</h2>

        <div :if={Enum.empty?(@seasons)} class="text-center py-12">
          <.icon name="hero-film" class="size-16 mx-auto mb-4 text-white/20" />
          <p class="text-white/60">Nenhum episódio disponível</p>
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
    """
  end

  defp season_accordion(assigns) do
    episodes = Enum.sort_by(assigns.season.episodes || [], & &1.episode_num)
    assigns = assign(assigns, :episodes, episodes)

    ~H"""
    <div class="bg-white/5 rounded-lg overflow-hidden">
      <button
        type="button"
        phx-click="toggle_season"
        phx-value-id={@season.id}
        class="w-full flex items-center justify-between px-5 py-4 hover:bg-white/5 transition-colors"
      >
        <div class="flex items-center gap-4">
          <span class="text-lg font-semibold text-white">Temporada {@season.season_number}</span>
          <span class="text-sm text-white/50">{length(@episodes)} episódios</span>
        </div>
        <.icon
          name="hero-chevron-down"
          class={["size-5 text-white/50 transition-transform duration-200", @expanded && "rotate-180"]}
        />
      </button>

      <div :if={@expanded} class="border-t border-white/10">
        <div class="divide-y divide-white/5">
          <.episode_item :for={episode <- @episodes} episode={episode} />
        </div>
      </div>
    </div>
    """
  end

  defp episode_item(assigns) do
    ~H"""
    <div
      class="flex gap-4 p-4 hover:bg-white/5 cursor-pointer transition-colors group"
      phx-click="play_episode"
      phx-value-id={@episode.id}
    >
      <%!-- Episode Number --%>
      <div class="flex-shrink-0 w-8 text-center">
        <span class="text-2xl font-bold text-white/30">{@episode.episode_num}</span>
      </div>

      <%!-- Thumbnail --%>
      <div class="relative flex-shrink-0 w-36 aspect-video bg-white/10 rounded overflow-hidden">
        <img
          :if={@episode.cover}
          src={@episode.cover}
          alt={episode_title(@episode)}
          class="w-full h-full object-cover"
          loading="lazy"
        />
        <div :if={!@episode.cover} class="w-full h-full flex items-center justify-center bg-neutral-800">
          <.icon name="hero-play-circle" class="size-10 text-white/40" />
        </div>

        <%!-- Play overlay --%>
        <div class="absolute inset-0 bg-black/50 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <div class="w-10 h-10 rounded-full bg-white flex items-center justify-center">
            <.icon name="hero-play-solid" class="size-5 text-black ml-0.5" />
          </div>
        </div>
      </div>

      <%!-- Info --%>
      <div class="flex-1 min-w-0">
        <h4 class="font-medium text-white group-hover:text-white/90 truncate">
          {episode_title(@episode)}
        </h4>
        <p :if={@episode.plot} class="text-sm text-white/50 line-clamp-2 mt-1">
          {@episode.plot}
        </p>
        <span :if={@episode.duration} class="text-xs text-white/40 mt-2 block">
          {@episode.duration}
        </span>
      </div>
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  # Simple episode title - just "Episódio X" since series name is in the header
  defp episode_title(episode), do: "Episódio #{episode.episode_num}"

  defp format_rating(rating) when is_number(rating), do: Float.round(rating / 2, 1) |> to_string()
  defp format_rating(_), do: nil

  defp get_backdrop(%{backdrop_path: [url | _]}) when is_binary(url), do: url
  defp get_backdrop(_), do: nil
end
