defmodule StreamixWeb.FavoritesLive do
  @moduledoc """
  LiveView for displaying user's favorite content.

  Features:
  - Grid display of favorites by content type
  - Content type filtering (all, live, movies, series)
  - Quick play functionality
  - Remove from favorites
  """
  use StreamixWeb, :live_view

  import StreamixWeb.AppComponents

  alias Streamix.Iptv

  @doc false
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    favorites = Iptv.list_favorites(user_id)

    socket =
      socket
      |> assign(page_title: "Favoritos")
      |> assign(current_path: "/favorites")
      |> assign(favorites: favorites)
      |> assign(filter: "all")
      |> assign(filtered_favorites: favorites)

    {:ok, socket}
  end

  # ============================================
  # Event Handlers
  # ============================================

  @doc false
  def handle_event("filter", %{"type" => type}, socket) do
    filtered =
      if type == "all" do
        socket.assigns.favorites
      else
        Enum.filter(socket.assigns.favorites, &(&1.content_type == type))
      end

    {:noreply, assign(socket, filter: type, filtered_favorites: filtered)}
  end

  def handle_event("play", %{"id" => id, "type" => type}, socket) do
    path = get_play_path(type, id)
    {:noreply, push_navigate(socket, to: path)}
  end

  def handle_event("remove_favorite", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    favorite_id = String.to_integer(id)

    case Enum.find(socket.assigns.favorites, &(&1.id == favorite_id)) do
      nil ->
        {:noreply, socket}

      favorite ->
        Iptv.remove_favorite(user_id, favorite.content_type, favorite.content_id)

        favorites = Enum.reject(socket.assigns.favorites, &(&1.id == favorite_id))

        filtered =
          if socket.assigns.filter == "all" do
            favorites
          else
            Enum.filter(favorites, &(&1.content_type == socket.assigns.filter))
          end

        {:noreply, assign(socket, favorites: favorites, filtered_favorites: filtered)}
    end
  end

  # ============================================
  # Render
  # ============================================

  @doc false
  def render(assigns) do
    ~H"""
    <div class="px-[4%] py-8 space-y-8">
      <div class="flex items-center justify-between flex-wrap gap-4">
        <h1 class="text-3xl font-bold text-text-primary">Minha Lista</h1>

        <div class="flex gap-2">
          <.filter_button type="all" label="Todos" current={@filter} count={length(@favorites)} />
          <.filter_button
            type="live_channel"
            label="Ao Vivo"
            current={@filter}
            count={count_by_type(@favorites, "live_channel")}
          />
          <.filter_button
            type="movie"
            label="Filmes"
            current={@filter}
            count={count_by_type(@favorites, "movie")}
          />
          <.filter_button
            type="series"
            label="Séries"
            current={@filter}
            count={count_by_type(@favorites, "series")}
          />
        </div>
      </div>

      <div
        :if={Enum.any?(@filtered_favorites)}
        class="grid gap-4 grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6"
      >
        <.favorite_item :for={favorite <- @filtered_favorites} favorite={favorite} />
      </div>

      <.empty_state
        :if={Enum.empty?(@filtered_favorites)}
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

  defp favorite_item(assigns) do
    ~H"""
    <div class="bg-surface rounded-lg overflow-hidden hover:bg-surface-hover transition-colors group">
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

  defp count_by_type(favorites, type) do
    Enum.count(favorites, &(&1.content_type == type))
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
