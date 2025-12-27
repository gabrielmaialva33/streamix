defmodule StreamixWeb.HistoryLive do
  @moduledoc """
  LiveView for displaying user's watch history.

  Features:
  - Chronological list of watched content
  - Content type filtering
  - Resume playback with progress
  - Clear history functionality
  """
  use StreamixWeb, :live_view

  import StreamixWeb.AppComponents

  alias Streamix.Iptv

  @doc false
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    history = Iptv.list_watch_history(user_id)

    socket =
      socket
      |> assign(page_title: "Histórico")
      |> assign(current_path: "/history")
      |> assign(history: history)
      |> assign(filter: "all")
      |> assign(filtered_history: history)

    {:ok, socket}
  end

  # ============================================
  # Event Handlers
  # ============================================

  @doc false
  def handle_event("filter", %{"type" => type}, socket) do
    filtered =
      if type == "all" do
        socket.assigns.history
      else
        Enum.filter(socket.assigns.history, &(&1.content_type == type))
      end

    {:noreply, assign(socket, filter: type, filtered_history: filtered)}
  end

  def handle_event("play", %{"id" => id, "type" => type}, socket) do
    path = get_play_path(type, id)
    {:noreply, push_navigate(socket, to: path)}
  end

  def handle_event("remove_entry", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    entry_id = String.to_integer(id)

    Iptv.remove_from_watch_history(user_id, entry_id)

    history = Enum.reject(socket.assigns.history, &(&1.id == entry_id))

    filtered =
      if socket.assigns.filter == "all" do
        history
      else
        Enum.filter(history, &(&1.content_type == socket.assigns.filter))
      end

    {:noreply, assign(socket, history: history, filtered_history: filtered)}
  end

  def handle_event("clear_history", _, socket) do
    user_id = socket.assigns.current_scope.user.id
    Iptv.clear_watch_history(user_id)

    {:noreply, assign(socket, history: [], filtered_history: [])}
  end

  # ============================================
  # Render
  # ============================================

  @doc false
  def render(assigns) do
    ~H"""
    <div class="px-[4%] py-8 space-y-8">
      <div class="flex items-center justify-between flex-wrap gap-4">
        <h1 class="text-3xl font-bold text-text-primary">Histórico</h1>

        <div class="flex items-center gap-4">
          <div class="flex gap-2">
            <.filter_button type="all" label="Todos" current={@filter} count={length(@history)} />
            <.filter_button
              type="live_channel"
              label="Ao Vivo"
              current={@filter}
              count={count_by_type(@history, "live_channel")}
            />
            <.filter_button
              type="movie"
              label="Filmes"
              current={@filter}
              count={count_by_type(@history, "movie")}
            />
            <.filter_button
              type="episode"
              label="Episódios"
              current={@filter}
              count={count_by_type(@history, "episode")}
            />
          </div>

          <button
            :if={Enum.any?(@history)}
            type="button"
            phx-click="clear_history"
            data-confirm="Tem certeza que deseja limpar todo o histórico?"
            class="px-3 py-2 text-sm text-red-500 hover:bg-red-500/10 rounded-lg transition-colors"
          >
            <.icon name="hero-trash" class="size-4" /> Limpar
          </button>
        </div>
      </div>

      <div :if={Enum.any?(@filtered_history)} class="space-y-3">
        <.history_entry :for={entry <- @filtered_history} entry={entry} />
      </div>

      <.empty_state
        :if={Enum.empty?(@filtered_history)}
        icon="hero-clock"
        title={empty_title(@filter)}
        message={empty_message(@filter)}
      />
    </div>
    """
  end

  defp filter_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="filter"
      phx-value-type={@type}
      class={[
        "px-4 py-2 text-sm font-medium rounded-lg transition-colors",
        @current == @type && "bg-brand text-white",
        @current != @type &&
          "bg-surface text-text-secondary hover:bg-surface-hover hover:text-text-primary"
      ]}
    >
      {@label}
      <span :if={@count > 0} class="ml-2 px-1.5 py-0.5 text-xs rounded bg-white/20">{@count}</span>
    </button>
    """
  end

  defp history_entry(assigns) do
    ~H"""
    <div class="flex items-center gap-4 p-4 rounded-lg bg-surface hover:bg-surface-hover transition-colors group">
      <div
        class="relative w-24 h-16 rounded bg-surface-hover flex items-center justify-center flex-shrink-0 overflow-hidden cursor-pointer"
        phx-click="play"
        phx-value-id={@entry.content_id}
        phx-value-type={@entry.content_type}
      >
        <img
          :if={@entry.content_icon}
          src={@entry.content_icon}
          alt={@entry.content_name}
          class="w-full h-full object-contain"
          loading="lazy"
        />
        <.icon
          :if={!@entry.content_icon}
          name={content_type_icon(@entry.content_type)}
          class="size-8 text-text-secondary/30"
        />
        <div class="absolute inset-0 bg-black/50 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <.icon name="hero-play-solid" class="size-8 text-white" />
        </div>

        <.progress_indicator
          :if={progress_percent(@entry) > 0}
          percent={progress_percent(@entry)}
        />
      </div>

      <div
        class="flex-1 min-w-0 cursor-pointer"
        phx-click="play"
        phx-value-id={@entry.content_id}
        phx-value-type={@entry.content_type}
      >
        <h4 class="font-medium text-text-primary truncate">
          {@entry.content_name || "Desconhecido"}
        </h4>
        <div class="flex items-center gap-2 text-sm text-text-secondary mt-1">
          <span class="px-2 py-0.5 text-xs rounded bg-surface-hover">
            {format_content_type(@entry.content_type)}
          </span>
          <span>{format_relative_time(@entry.watched_at)}</span>
          <span :if={@entry.duration_seconds}>
            · {format_duration(@entry.duration_seconds)}
          </span>
        </div>
      </div>

      <button
        type="button"
        phx-click="remove_entry"
        phx-value-id={@entry.id}
        class="p-2 text-text-secondary hover:text-text-primary opacity-0 group-hover:opacity-100 transition-all"
        title="Remover do histórico"
      >
        <.icon name="hero-x-mark" class="size-5" />
      </button>
    </div>
    """
  end

  defp progress_indicator(assigns) do
    ~H"""
    <div class="absolute bottom-0 left-0 right-0 h-1 bg-black/50">
      <div class="h-full bg-brand" style={"width: #{@percent}%"}></div>
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp count_by_type(history, type) do
    Enum.count(history, &(&1.content_type == type))
  end

  defp progress_percent(%{progress_seconds: progress, duration_seconds: duration})
       when is_integer(progress) and is_integer(duration) and duration > 0 do
    round(progress / duration * 100)
  end

  defp progress_percent(_), do: 0

  defp get_play_path("live_channel", id), do: ~p"/watch/live_channel/#{id}"
  defp get_play_path("movie", id), do: ~p"/watch/movie/#{id}"
  defp get_play_path("episode", id), do: ~p"/watch/episode/#{id}"
  defp get_play_path(_, _), do: ~p"/"

  defp content_type_icon("live_channel"), do: "hero-tv"
  defp content_type_icon("movie"), do: "hero-film"
  defp content_type_icon("series"), do: "hero-video-camera"
  defp content_type_icon("episode"), do: "hero-play"
  defp content_type_icon(_), do: "hero-play-circle"

  defp format_content_type("live_channel"), do: "Ao Vivo"
  defp format_content_type("movie"), do: "Filme"
  defp format_content_type("series"), do: "Série"
  defp format_content_type("episode"), do: "Episódio"
  defp format_content_type(type), do: type || "Desconhecido"

  defp format_relative_time(nil), do: ""

  defp format_relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "agora mesmo"
      diff < 3600 -> "#{div(diff, 60)} min atrás"
      diff < 86_400 -> "#{div(diff, 3600)}h atrás"
      diff < 604_800 -> "#{div(diff, 86_400)} dias atrás"
      true -> Calendar.strftime(datetime, "%d/%m/%Y")
    end
  end

  defp format_duration(seconds) when is_integer(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}min"
      minutes > 0 -> "#{minutes}min"
      true -> "< 1min"
    end
  end

  defp format_duration(_), do: ""

  defp empty_title("all"), do: "Nenhum histórico"
  defp empty_title("live_channel"), do: "Nenhum canal assistido"
  defp empty_title("movie"), do: "Nenhum filme assistido"
  defp empty_title("episode"), do: "Nenhum episódio assistido"
  defp empty_title(_), do: "Nenhum histórico"

  defp empty_message("all"), do: "Seu histórico de visualização aparecerá aqui."
  defp empty_message("live_channel"), do: "Os canais que você assistir aparecerão aqui."
  defp empty_message("movie"), do: "Os filmes que você assistir aparecerão aqui."
  defp empty_message("episode"), do: "Os episódios que você assistir aparecerão aqui."
  defp empty_message(_), do: "Seu histórico aparecerá aqui."
end
