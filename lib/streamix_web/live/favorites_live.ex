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

  import StreamixWeb.App.Feedback
  import StreamixWeb.Content.CardComponents
  import StreamixWeb.Helpers.Params, only: [parse_positive_integer: 1]

  alias Streamix.Library
  alias StreamixWeb.Helpers.ImageProxy

  @per_page 24

  @doc false
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    user_id = user.id
    show_adult = user.show_adult_content

    # Load all favorites for offline sync (limited to recent 100)
    sync_favorites = load_favorites_for_sync(user_id, show_adult)

    socket =
      socket
      |> assign(page_title: "Favoritos")
      |> assign(current_path: "/favorites")
      |> assign(user_id: user_id)
      |> assign(show_adult: show_adult)
      |> assign(filter: "all")
      |> assign(page: 0)
      |> assign(loading: false)
      |> assign(end_of_list: false)
      |> assign(counts: load_counts(user_id, show_adult))
      |> assign(sync_favorites: sync_favorites)
      |> stream(:favorites, [])
      |> load_favorites()

    {:ok, socket, temporary_assigns: [loading: false]}
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
    socket =
      if socket.assigns.loading || socket.assigns.end_of_list do
        socket
      else
        socket
        |> assign(page: socket.assigns.page + 1)
        |> assign(loading: true)
        |> load_favorites()
      end

    {:reply, %{page: socket.assigns.page}, socket}
  end

  def handle_event("play", %{"id" => id, "type" => type}, socket) do
    path = get_play_path(type, id)
    {:noreply, redirect(socket, to: path)}
  end

  def handle_event(
        "remove_favorite",
        %{"type" => type, "content_id" => content_id},
        socket
      ) do
    user_id = socket.assigns.user_id

    case parse_positive_integer(content_id) do
      {:ok, content_id_int} ->
        Library.remove_favorite(user_id, type, content_id_int)

        # Update counts
        counts = update_counts(socket.assigns.counts, type, -1)

        socket =
          socket
          |> stream_delete_by_dom_id(:favorites, "favorites-#{type}-#{content_id}")
          |> assign(counts: counts)

        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  # OfflineSync hook events (client-side sync, no server action needed)
  def handle_event("refresh_data", _params, socket), do: {:noreply, socket}

  # ============================================
  # Render
  # ============================================

  @doc false
  def render(assigns) do
    ~H"""
    <div class="space-y-6 sm:space-y-8">
      <!-- Offline Sync Hook -->
      <div
        id="favorites-sync"
        phx-hook="OfflineSync"
        data-sync-type="favorites"
        data-sync-data={Jason.encode!(@sync_favorites)}
        class="hidden"
      />

      <div class="space-y-3 sm:space-y-0 sm:flex sm:items-center sm:justify-between">
        <h1 class="text-2xl sm:text-3xl font-bold text-text-primary">Minha Lista</h1>

        <div id="favorites-filter-strip" data-filter-strip class="filter-strip">
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
        class="responsive-wide-grid"
      >
        <.favorite_item
          :for={{dom_id, favorite} <- @streams.favorites}
          id={dom_id}
          favorite={favorite}
        />
      </div>
      <.infinite_scroll_sentinel
        :if={!@end_of_list && !@loading}
        id="favorites-sentinel"
        page={@page}
        stream_target="#favorites-grid"
      />

      <div :if={@loading} class="flex justify-center py-8">
        <.loading_spinner size="lg" />
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
        "min-h-11 flex-shrink-0 whitespace-nowrap rounded-lg px-3 py-1.5 text-xs font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-brand sm:px-4 sm:py-2 sm:text-sm",
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

  defp favorite_item(assigns) do
    assigns =
      assigns
      |> assign(:poster?, assigns.favorite.content_type in ["movie", "series"])
      |> assign(
        :image_url,
        case assigns.favorite.content_icon do
          icon when is_binary(icon) and icon != "" -> ImageProxy.proxy(icon)
          _other -> nil
        end
      )
      |> assign(:title, assigns.favorite.content_name || "Desconhecido")

    ~H"""
    <.poster_media_card
      :if={@poster?}
      id={@id}
      image_id={"favorite-image-#{@favorite.content_type}-#{@favorite.content_id}"}
      title={@title}
      subtitle={format_content_type(@favorite.content_type)}
      image_url={@image_url}
      fallback_icon={content_type_icon(@favorite.content_type)}
      content_id={@favorite.content_id}
      content_type={@favorite.content_type}
      on_click="play"
      data-favorite-kind="poster"
      class="catalog-stream-item catalog-stream-item--poster self-start border border-transparent hover:border-border"
    >
      <:badge>
        <span class="rounded bg-black/65 px-2 py-0.5 text-2xs font-medium text-white backdrop-blur-sm">
          {format_content_type(@favorite.content_type)}
        </span>
      </:badge>
      <:secondary_action>
        <.remove_favorite_button favorite={@favorite} />
      </:secondary_action>
    </.poster_media_card>

    <.landscape_media_card
      :if={!@poster?}
      id={@id}
      image_id={"favorite-image-#{@favorite.content_type}-#{@favorite.content_id}"}
      title={@title}
      subtitle={format_content_type(@favorite.content_type)}
      image_url={@image_url}
      image_fit={if @favorite.content_type == "live_channel", do: "contain", else: "cover"}
      fallback_icon={content_type_icon(@favorite.content_type)}
      content_id={@favorite.content_id}
      content_type={@favorite.content_type}
      on_click="play"
      data-favorite-kind="wide"
      class="catalog-stream-item catalog-stream-item--wide self-start border border-transparent hover:border-border"
    >
      <:badge>
        <span class="rounded bg-black/65 px-2 py-0.5 text-2xs font-medium text-white backdrop-blur-sm">
          {format_content_type(@favorite.content_type)}
        </span>
      </:badge>
      <:secondary_action>
        <.remove_favorite_button favorite={@favorite} />
      </:secondary_action>
    </.landscape_media_card>
    """
  end

  attr :favorite, :map, required: true

  defp remove_favorite_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="remove_favorite"
      phx-value-type={@favorite.content_type}
      phx-value-content_id={@favorite.content_id}
      class="flex size-11 items-center justify-center rounded-md bg-surface/90 text-text-secondary shadow-sm transition-all hover:bg-error/10 hover:text-error focus:outline-none focus:ring-2 focus:ring-error"
      aria-label="Remover dos favoritos"
    >
      <.icon name="hero-trash" class="size-4" />
    </button>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp load_favorites(socket) do
    user_id = socket.assigns.user_id
    filter = socket.assigns.filter
    page = socket.assigns.page
    offset = page * @per_page

    opts = [limit: @per_page, offset: offset, show_adult: socket.assigns.show_adult]
    opts = if filter != "all", do: Keyword.put(opts, :content_type, filter), else: opts

    favorites =
      Library.list_favorites(user_id, opts)
      |> Enum.map(fn f -> Map.put(f, :id, "#{f.content_type}-#{f.content_id}") end)

    socket
    |> assign(loading: false)
    |> assign(end_of_list: length(favorites) < @per_page)
    |> stream(:favorites, favorites)
  end

  defp load_counts(user_id, show_adult) do
    Library.count_favorites_by_type(user_id, show_adult: show_adult)
  end

  defp load_favorites_for_sync(user_id, show_adult) do
    # Load recent favorites for offline sync
    Library.list_favorites(user_id, limit: 100, show_adult: show_adult)
    |> Enum.map(fn f ->
      %{
        content_type: f.content_type,
        content_id: f.content_id,
        content_name: f.content_name,
        content_icon: f.content_icon
      }
    end)
  end

  defp update_counts(counts, type, delta) do
    Map.update(counts, type, 0, &max(0, &1 + delta))
  end

  defp total_count(counts) do
    Enum.reduce(counts, 0, fn {_type, count}, acc -> acc + count end)
  end

  defp get_play_path("live_channel", id), do: ~p"/watch/live_channel/#{id}"
  defp get_play_path("movie", id), do: ~p"/watch/movie/#{id}"
  defp get_play_path("series", id), do: ~p"/browse/series/#{id}"
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
