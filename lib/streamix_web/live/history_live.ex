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

  import StreamixWeb.App.Feedback
  import StreamixWeb.Content.CardComponents
  import StreamixWeb.Helpers.Params, only: [parse_positive_integer: 1]

  alias Streamix.Iptv
  alias StreamixWeb.Helpers.ImageProxy

  @per_page 20

  @doc false
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    user_id = user.id
    show_adult = user.show_adult_content

    # Load history for offline sync (limited to recent 100)
    sync_history = load_history_for_sync(user_id, show_adult)

    socket =
      socket
      |> assign(page_title: "Histórico")
      |> assign(current_path: "/history")
      |> assign(user_id: user_id)
      |> assign(show_adult: show_adult)
      |> assign(filter: "all")
      |> assign(page: 0)
      |> assign(loading: false)
      |> assign(end_of_list: false)
      |> assign(counts: load_counts(user_id, show_adult))
      |> assign(sync_history: sync_history)
      |> stream(:history, [])
      |> load_history()

    {:ok, socket, temporary_assigns: [loading: false]}
  end

  # ============================================
  # Event Handlers
  # ============================================

  # OfflineSync hook events (client-side sync, no server action needed)
  def handle_event("refresh_data", _params, socket), do: {:noreply, socket}

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
    socket =
      if socket.assigns.loading || socket.assigns.end_of_list do
        socket
      else
        socket
        |> assign(page: socket.assigns.page + 1)
        |> assign(loading: true)
        |> load_history()
      end

    {:reply, %{page: socket.assigns.page}, socket}
  end

  def handle_event("play", %{"id" => id, "type" => type}, socket) do
    path = get_play_path(type, id)
    {:noreply, redirect(socket, to: path)}
  end

  def handle_event("remove_entry", %{"id" => id, "type" => type}, socket) do
    user_id = socket.assigns.user_id

    case parse_positive_integer(id) do
      {:ok, entry_id} ->
        Iptv.remove_from_watch_history(user_id, entry_id)

        # Update counts
        counts = update_counts(socket.assigns.counts, type, -1)

        socket =
          socket
          |> stream_delete_by_dom_id(:history, "history-#{entry_id}")
          |> assign(counts: counts)

        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
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
      <!-- Offline Sync Hook -->
      <div
        id="history-sync"
        phx-hook="OfflineSync"
        data-sync-type="history"
        data-sync-data={Jason.encode!(@sync_history)}
        class="hidden"
      />

      <div class="space-y-3 sm:space-y-0 sm:flex sm:items-center sm:justify-between">
        <h1 class="text-2xl sm:text-3xl font-bold text-text-primary">Histórico</h1>

        <div class="flex min-w-0 items-center gap-2 sm:justify-end sm:gap-4">
          <div id="history-filter-strip" data-filter-strip class="filter-strip min-w-0 flex-1">
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
              label="Episódios"
              current={@filter}
              count={@counts["episode"] || 0}
            />
          </div>

          <button
            :if={total_count(@counts) > 0}
            type="button"
            phx-click="clear_history"
            data-confirm="Tem certeza que deseja limpar todo o histórico?"
            aria-label="Limpar todo o histórico"
            class="flex size-11 flex-shrink-0 items-center justify-center rounded-lg text-error transition-colors hover:bg-error/10 focus:outline-none focus:ring-2 focus:ring-error sm:w-auto sm:px-3"
          >
            <.icon name="hero-trash" class="size-4" />
            <span class="hidden sm:inline ml-1">Limpar</span>
          </button>
        </div>
      </div>

      <div
        id="history-list"
        phx-update="stream"
        class="responsive-wide-grid"
      >
        <.history_entry :for={{dom_id, entry} <- @streams.history} id={dom_id} entry={entry} />
      </div>
      <.infinite_scroll_sentinel
        :if={!@end_of_list && !@loading}
        id="history-sentinel"
        page={@page}
        stream_target="#history-list"
      />

      <div :if={@loading} class="flex justify-center py-8">
        <.loading_spinner size="lg" />
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
        "min-h-11 px-3 sm:px-4 py-1.5 sm:py-2 text-xs sm:text-sm font-medium rounded-lg transition-colors whitespace-nowrap flex-shrink-0 focus:outline-none focus:ring-2 focus:ring-brand",
        @current == @type && "bg-brand text-white",
        @current != @type &&
          "bg-surface text-text-secondary hover:bg-surface-hover hover:text-text-primary border border-border"
      ]}
    >
      {@label}
      <span
        :if={@count > 0}
        class="ml-1.5 sm:ml-2 px-1.5 py-0.5 text-2xs rounded bg-black/20"
      >
        {@count}
      </span>
    </button>
    """
  end

  defp history_entry(assigns) do
    assigns =
      assigns
      |> assign(
        :image_url,
        case assigns.entry.content_icon do
          icon when is_binary(icon) and icon != "" -> ImageProxy.proxy(icon)
          _other -> nil
        end
      )
      |> assign(:title, assigns.entry.content_name || "Desconhecido")

    ~H"""
    <.landscape_media_card
      id={@id}
      image_id={"history-image-#{@entry.id}"}
      title={@title}
      subtitle={format_relative_time(@entry.watched_at)}
      image_url={@image_url}
      image_fit={if @entry.content_type == "live_channel", do: "contain", else: "cover"}
      fallback_icon={content_type_icon(@entry.content_type)}
      content_id={@entry.content_id}
      content_type={@entry.content_type}
      on_click="play"
      progress={progress_percent(@entry) / 100}
      data-history-entry
      class="catalog-stream-item catalog-stream-item--wide self-start border border-transparent hover:border-border"
    >
      <:badge>
        <span class="rounded bg-black/65 px-2 py-0.5 text-2xs font-medium text-white backdrop-blur-sm">
          {format_content_type(@entry.content_type)}
        </span>
      </:badge>
      <:metadata>
        <div class="mt-2 flex items-center gap-2 text-xs text-text-muted">
          <span :if={@entry.duration_seconds}>
            {format_duration(@entry.duration_seconds)}
          </span>
        </div>
      </:metadata>
      <:secondary_action>
        <button
          type="button"
          phx-click="remove_entry"
          phx-value-id={@entry.id}
          phx-value-type={@entry.content_type}
          class="flex size-11 items-center justify-center rounded-md bg-surface/90 text-text-secondary shadow-sm transition-all hover:bg-error/10 hover:text-error focus:outline-none focus:ring-2 focus:ring-error"
          aria-label="Remover do histórico"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </:secondary_action>
    </.landscape_media_card>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp load_history(socket) do
    user_id = socket.assigns.user_id
    filter = socket.assigns.filter
    page = socket.assigns.page
    offset = page * @per_page

    opts = [limit: @per_page, offset: offset, show_adult: socket.assigns.show_adult]
    opts = if filter != "all", do: Keyword.put(opts, :content_type, filter), else: opts

    history = Iptv.list_watch_history(user_id, opts)

    socket
    |> assign(loading: false)
    |> assign(end_of_list: length(history) < @per_page)
    |> stream(:history, history)
  end

  defp load_counts(user_id, show_adult) do
    Iptv.count_watch_history_by_type(user_id, show_adult: show_adult)
  end

  defp load_history_for_sync(user_id, show_adult) do
    # Load recent history for offline sync
    Iptv.list_watch_history(user_id, limit: 100, show_adult: show_adult)
    |> Enum.map(fn h ->
      %{
        id: h.id,
        content_type: h.content_type,
        content_id: h.content_id,
        content_name: h.content_name,
        content_icon: h.content_icon,
        progress_seconds: h.progress_seconds,
        duration_seconds: h.duration_seconds,
        watched_at: h.watched_at
      }
    end)
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
