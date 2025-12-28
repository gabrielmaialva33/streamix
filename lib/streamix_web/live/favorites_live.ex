defmodule StreamixWeb.FavoritesLive do
  @moduledoc """
  LiveView for displaying user's favorite content.

  Features:
  - Grid display of favorites by content type
  - Content type filtering (all, live, movies, series)
  - Quick play functionality
  - Remove from favorites
  - Infinite scroll with pagination using LiveView streams
  """
  use StreamixWeb, :live_view

  import StreamixWeb.AppComponents

  alias Streamix.Iptv

  @page_size 24

  @doc false
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    socket =
      socket
      |> assign(page_title: "Favoritos")
      |> assign(current_path: "/favorites")
      |> assign(user_id: user_id)
      |> assign(filter: "all")
      |> assign(page: 0)
      |> assign(loading: false)
      |> assign(end_of_list: false)
      |> assign(counts: load_counts(user_id))
      |> stream(:favorites, [])
      |> load_favorites()

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
      |> stream(:favorites, [], reset: true)
      |> load_favorites()

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
        |> load_favorites()

      {:noreply, socket}
    end
  end

  def handle_event("play", %{"id" => id, "type" => type}, socket) do
    path = get_play_path(type, id)
    {:noreply, push_navigate(socket, to: path)}
  end

  def handle_event(
        "remove_favorite",
        %{"id" => id, "type" => type, "content_id" => content_id},
        socket
      ) do
    user_id = socket.assigns.user_id
    favorite_id = String.to_integer(id)
    content_id = String.to_integer(content_id)

    Iptv.remove_favorite(user_id, type, content_id)

    # Update counts
    counts = update_counts(socket.assigns.counts, type, -1)

    socket =
      socket
      |> stream_delete_by_dom_id(:favorites, "favorites-#{favorite_id}")
      |> assign(counts: counts)

    {:noreply, socket}
  end

  # ============================================
  # Render
  # ============================================

  @doc false
  def render(assigns) do
    ~H"""
    <div class="space-y-6 sm:space-y-8">
      <div class="space-y-3 sm:space-y-0 sm:flex sm:items-center sm:justify-between">
        <h1 class="text-2xl sm:text-3xl font-bold text-text-primary">Minha Lista</h1>

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
            type="series"
            label="Séries"
            current={@filter}
            count={@counts["series"] || 0}
          />
        </div>
      </div>

      <div
        id="favorites-grid"
        phx-update="stream"
        phx-viewport-bottom={!@end_of_list && "load_more"}
        class="grid gap-4 grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6"
      >
        <.favorite_item
          :for={{dom_id, favorite} <- @streams.favorites}
          id={dom_id}
          favorite={favorite}
        />
      </div>

      <div :if={@loading} class="flex justify-center py-8">
        <.icon name="hero-arrow-path" class="size-8 text-brand animate-spin" />
      </div>

      <.empty_state
        :if={total_count(@counts) == 0}
        icon="hero-heart"
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

  defp favorite_item(assigns) do
    ~H"""
    <div
      id={@id}
      class="bg-surface rounded-lg overflow-hidden hover:bg-surface-hover transition-colors group"
    >
      <div
        class="relative aspect-video bg-surface-hover cursor-pointer"
        phx-click="play"
        phx-value-id={@favorite.content_id}
        phx-value-type={@favorite.content_type}
      >
        <img
          :if={@favorite.content_icon}
          src={@favorite.content_icon}
          alt={@favorite.content_name}
          class="w-full h-full object-contain p-2"
          loading="lazy"
        />
        <div
          :if={!@favorite.content_icon}
          class="w-full h-full flex items-center justify-center text-text-secondary/30"
        >
          <.icon name={content_type_icon(@favorite.content_type)} class="size-12" />
        </div>
        <div class="absolute inset-0 bg-black/50 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <.icon name="hero-play-circle-solid" class="size-16 text-brand" />
        </div>
        <span class="absolute top-2 left-2 px-2 py-0.5 text-xs rounded bg-black/60 text-white">
          {format_content_type(@favorite.content_type)}
        </span>
      </div>
      <div class="p-3">
        <div class="flex items-start justify-between gap-2">
          <h3
            class="font-medium text-sm text-text-primary truncate flex-1"
            title={@favorite.content_name}
          >
            {@favorite.content_name || "Desconhecido"}
          </h3>
          <button
            type="button"
            phx-click="remove_favorite"
            phx-value-id={@favorite.id}
            phx-value-type={@favorite.content_type}
            phx-value-content_id={@favorite.content_id}
            class="p-1 text-red-500 opacity-0 group-hover:opacity-100 transition-opacity hover:bg-red-500/20 rounded"
            title="Remover dos favoritos"
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp load_favorites(socket) do
    user_id = socket.assigns.user_id
    filter = socket.assigns.filter
    page = socket.assigns.page
    offset = page * @page_size

    opts = [limit: @page_size, offset: offset]
    opts = if filter != "all", do: Keyword.put(opts, :content_type, filter), else: opts

    favorites = Iptv.list_favorites(user_id, opts)

    socket
    |> assign(loading: false)
    |> assign(end_of_list: length(favorites) < @page_size)
    |> stream(:favorites, favorites)
  end

  defp load_counts(user_id) do
    Iptv.count_favorites_by_type(user_id)
  end

  defp update_counts(counts, type, delta) do
    Map.update(counts, type, 0, &max(0, &1 + delta))
  end

  defp total_count(counts) do
    Enum.reduce(counts, 0, fn {_type, count}, acc -> acc + count end)
  end

  defp get_play_path("live_channel", id), do: ~p"/watch/live_channel/#{id}"
  defp get_play_path("movie", id), do: ~p"/watch/movie/#{id}"
  defp get_play_path("series", id), do: ~p"/providers/0/series/#{id}"
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

  defp empty_title("all"), do: "Nenhum favorito"
  defp empty_title("live_channel"), do: "Nenhum canal favorito"
  defp empty_title("movie"), do: "Nenhum filme favorito"
  defp empty_title("series"), do: "Nenhuma série favorita"
  defp empty_title(_), do: "Nenhum favorito"

  defp empty_message("all"),
    do: "Adicione conteúdos aos seus favoritos para acessá-los rapidamente."

  defp empty_message("live_channel"), do: "Favorite canais ao vivo para acessá-los aqui."
  defp empty_message("movie"), do: "Favorite filmes para acessá-los aqui."
  defp empty_message("series"), do: "Favorite séries para acessá-las aqui."
  defp empty_message(_), do: "Adicione conteúdos aos seus favoritos."
end
