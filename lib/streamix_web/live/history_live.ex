defmodule StreamixWeb.HistoryLive do
  @moduledoc """
  LiveView for displaying user's watch history.

  Features:
  - Chronological list of watched content
  - Content type filtering
  - Resume playback with progress
  - Clear history functionality
  - Infinite scroll with pagination using LiveView streams
  """
  use StreamixWeb, :live_view

  import StreamixWeb.AppComponents

  alias Streamix.Iptv

  @page_size 20

  @doc false
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    socket =
      socket
      |> assign(page_title: "Historico")
      |> assign(current_path: "/history")
      |> assign(user_id: user_id)
      |> assign(filter: "all")
      |> assign(page: 0)
      |> assign(loading: false)
      |> assign(end_of_list: false)
      |> assign(counts: load_counts(user_id))
      |> stream(:history, [])
      |> load_history()

    {:ok, socket}
  end

  # ============================================
  # Event Handlers
  # ============================================

  @doc false
  def handle_event("filter", %{"type" => type}, socket) do
    socket =
      socket
      |> assign(filter: type)
      |> assign(page: 0)
      |> assign(end_of_list: false)
      |> stream(:history, [], reset: true)
      |> load_history()

    {:noreply, socket}
  end

  def handle_event("load_more", _, socket) do
    if socket.assigns.loading || socket.assigns.end_of_list do
      {:noreply, socket}
    else
      socket =
        socket
        |> assign(page: socket.assigns.page + 1)
        |> assign(loading: true)
        |> load_history()

      {:noreply, socket}
    end
  end

  def handle_event("play", %{"id" => id, "type" => type}, socket) do
    path = get_play_path(type, id)
    {:noreply, push_navigate(socket, to: path)}
  end

  def handle_event("remove_entry", %{"id" => id, "type" => type}, socket) do
    user_id = socket.assigns.user_id
    entry_id = String.to_integer(id)

    Iptv.remove_from_watch_history(user_id, entry_id)

    # Update counts
    counts = update_counts(socket.assigns.counts, type, -1)

    socket =
      socket
      |> stream_delete_by_dom_id(:history, "history-#{entry_id}")
      |> assign(counts: counts)

    {:noreply, socket}
  end

  def handle_event("clear_history", _, socket) do
    user_id = socket.assigns.user_id
    Iptv.clear_watch_history(user_id)

    socket =
      socket
      |> stream(:history, [], reset: true)
      |> assign(counts: %{})

    {:noreply, socket}
  end

  # ============================================
  # Render
  # ============================================

  @doc false
  def render(assigns) do
    ~H"""
    <div class="space-y-4 sm:space-y-6">
      <div class="space-y-3 sm:space-y-0 sm:flex sm:items-center sm:justify-between">
        <h1 class="text-2xl sm:text-3xl font-bold text-text-primary">Historico</h1>

        <div class="flex items-center justify-between sm:justify-end gap-2 sm:gap-4">
          <div class="flex gap-1.5 sm:gap-2 overflow-x-auto scrollbar-hide">
            <.filter_button type="all" label="Todos" current={@filter} count={total_count(@counts)} />
            <.filter_button
              type="live_channel"
              label="Ao Vivo"
              current={@filter}
              count={@counts["live_channel"] || 0}
            />
            <.filter_button
              type="movie"
              label="Filmes"
              current={@filter}
              count={@counts["movie"] || 0}
            />
            <.filter_button
              type="episode"
              label="Episodios"
              current={@filter}
              count={@counts["episode"] || 0}
            />
          </div>

          <button
            :if={total_count(@counts) > 0}
            type="button"
            phx-click="clear_history"
            data-confirm="Tem certeza que deseja limpar todo o historico?"
            class="px-2 sm:px-3 py-1.5 sm:py-2 text-xs sm:text-sm text-red-500 hover:bg-red-500/10 rounded-lg transition-colors flex-shrink-0"
          >
            <.icon name="hero-trash" class="size-4" />
            <span class="hidden sm:inline ml-1">Limpar</span>
          </button>
        </div>
      </div>

      <div
        id="history-list"
        phx-update="stream"
        phx-viewport-bottom={!@end_of_list && "load_more"}
        class="space-y-2 sm:space-y-3"
      >
        <.history_entry :for={{dom_id, entry} <- @streams.history} id={dom_id} entry={entry} />
      </div>

      <div :if={@loading} class="flex justify-center py-8">
        <.icon name="hero-arrow-path" class="size-8 text-brand animate-spin" />
      </div>

      <.empty_state
        :if={total_count(@counts) == 0}
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
        "px-3 sm:px-4 py-1.5 sm:py-2 text-xs sm:text-sm font-medium rounded-lg transition-colors whitespace-nowrap flex-shrink-0",
        @current == @type && "bg-brand text-white",
        @current != @type &&
          "bg-surface text-text-secondary hover:bg-surface-hover hover:text-text-primary"
      ]}
    >
      {@label}
      <span
        :if={@count > 0}
        class="ml-1.5 sm:ml-2 px-1.5 py-0.5 text-[10px] sm:text-xs rounded bg-white/20"
      >
        {@count}
      </span>
    </button>
    """
  end

  defp history_entry(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex items-center gap-3 sm:gap-4 p-3 sm:p-4 rounded-lg bg-surface hover:bg-surface-hover transition-colors group"
    >
      <div
        class="relative w-20 sm:w-24 h-14 sm:h-16 rounded bg-surface-hover flex items-center justify-center flex-shrink-0 overflow-hidden cursor-pointer"
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
          class="size-6 sm:size-8 text-text-secondary/30"
        />
        <div class="absolute inset-0 bg-black/50 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <.icon name="hero-play-solid" class="size-6 sm:size-8 text-white" />
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
        <h4 class="font-medium text-sm sm:text-base text-text-primary truncate">
          {@entry.content_name || "Desconhecido"}
        </h4>
        <div class="flex flex-wrap items-center gap-1.5 sm:gap-2 text-xs sm:text-sm text-text-secondary mt-0.5 sm:mt-1">
          <span class="px-1.5 sm:px-2 py-0.5 text-[10px] sm:text-xs rounded bg-surface-hover">
            {format_content_type(@entry.content_type)}
          </span>
          <span>{format_relative_time(@entry.watched_at)}</span>
          <span :if={@entry.duration_seconds}>
            . {format_duration(@entry.duration_seconds)}
          </span>
        </div>
      </div>

      <button
        type="button"
        phx-click="remove_entry"
        phx-value-id={@entry.id}
        phx-value-type={@entry.content_type}
        class="p-1.5 sm:p-2 text-text-secondary hover:text-text-primary sm:opacity-0 sm:group-hover:opacity-100 transition-all"
        title="Remover do historico"
      >
        <.icon name="hero-x-mark" class="size-4 sm:size-5" />
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

  defp load_history(socket) do
    user_id = socket.assigns.user_id
    filter = socket.assigns.filter
    page = socket.assigns.page
    offset = page * @page_size

    opts = [limit: @page_size, offset: offset]
    opts = if filter != "all", do: Keyword.put(opts, :content_type, filter), else: opts

    history = Iptv.list_watch_history(user_id, opts)

    socket
    |> assign(loading: false)
    |> assign(end_of_list: length(history) < @page_size)
    |> stream(:history, history)
  end

  defp load_counts(user_id) do
    Iptv.count_watch_history_by_type(user_id)
  end

  defp update_counts(counts, type, delta) do
    Map.update(counts, type, 0, &max(0, &1 + delta))
  end

  defp total_count(counts) do
    Enum.reduce(counts, 0, fn {_type, count}, acc -> acc + count end)
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
  defp format_content_type("series"), do: "Serie"
  defp format_content_type("episode"), do: "Episodio"
  defp format_content_type(type), do: type || "Desconhecido"

  defp format_relative_time(nil), do: ""

  defp format_relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "agora mesmo"
      diff < 3600 -> "#{div(diff, 60)} min atras"
      diff < 86_400 -> "#{div(diff, 3600)}h atras"
      diff < 604_800 -> "#{div(diff, 86_400)} dias atras"
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

  defp empty_title("all"), do: "Nenhum historico"
  defp empty_title("live_channel"), do: "Nenhum canal assistido"
  defp empty_title("movie"), do: "Nenhum filme assistido"
  defp empty_title("episode"), do: "Nenhum episodio assistido"
  defp empty_title(_), do: "Nenhum historico"

  defp empty_message("all"), do: "Seu historico de visualizacao aparecera aqui."
  defp empty_message("live_channel"), do: "Os canais que voce assistir aparecerao aqui."
  defp empty_message("movie"), do: "Os filmes que voce assistir aparecerao aqui."
  defp empty_message("episode"), do: "Os episodios que voce assistir aparecerao aqui."
  defp empty_message(_), do: "Seu historico aparecera aqui."
end
