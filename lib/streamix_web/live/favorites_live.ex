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
  import StreamixWeb.App.Filters, only: [filter_button: 1, filter_strip: 1]
  import StreamixWeb.Content.FavoriteComponents, only: [favorite_item: 1]
  import StreamixWeb.Helpers.Params, only: [parse_positive_integer: 1]

  alias Streamix.Library

  @per_page 24

  @doc false
  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    user_id = user.id
    show_adult = user.show_adult_content

    # Load all favorites for offline sync (limited to recent 100)
    sync_favorites = load_favorites_for_sync(user_id, show_adult)

    socket =
      socket
      |> assign(page_title: "Minha Lista")
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

    {:ok, socket, temporary_assigns: [loading: false]}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(filter: normalize_filter(params["type"]), page: 0, end_of_list: false)
     |> stream(:favorites, [], reset: true)
     |> load_favorites()}
  end

  defp normalize_filter(type) when type in ~w(all live_channel movie series episode), do: type
  defp normalize_filter(_type), do: "all"

  # ============================================
  # Event Handlers
  # ============================================

  @doc false
  @impl true
  def handle_event("filter", %{"type" => type}, socket) do
    type = normalize_filter(type)
    path = if type == "all", do: ~p"/favorites", else: ~p"/favorites?type=#{type}"
    {:noreply, push_patch(socket, to: path)}
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
  @impl true
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

      <div class="space-y-3">
        <.page_header id="favorites-page-header" title="Minha lista" icon="hero-heart" />

        <.filter_strip id="favorites-filter-strip">
          <.filter_button
            prefix="favorites"
            type="all"
            label="Todos"
            current={@filter}
            count={total_count(@counts)}
          />
          <.filter_button
            prefix="favorites"
            type="live_channel"
            label="Ao Vivo"
            current={@filter}
            count={@counts["live_channel"] || 0}
          />
          <.filter_button
            prefix="favorites"
            type="movie"
            label="Filmes"
            current={@filter}
            count={@counts["movie"] || 0}
          />
          <.filter_button
            prefix="favorites"
            type="series"
            label="Séries"
            current={@filter}
            count={@counts["series"] || 0}
          />
        </.filter_strip>
      </div>

      <div
        id="favorites-grid"
        phx-update="stream"
        class={grid_class(@filter)}
      >
        <.favorite_item
          :for={{dom_id, favorite} <- @streams.favorites}
          variant={:library}
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
        id="favorites-empty"
        icon="hero-heart"
        title={empty_title(@filter)}
        message={empty_message(@filter)}
        cta_label="Explorar catálogo"
        cta_navigate={empty_cta_path(@filter)}
      />
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp grid_class("live_channel"), do: "responsive-wide-grid"
  defp grid_class(_filter), do: "responsive-poster-grid"

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

  defp empty_cta_path("movie"), do: ~p"/browse/movies"
  defp empty_cta_path("series"), do: ~p"/browse/series"
  defp empty_cta_path(_), do: ~p"/browse"
end
