defmodule StreamixWeb.Gindex.AnimeLive do
  @moduledoc """
  LiveView for browsing GIndex animes.
  Shows a grid of animes with search functionality.
  """
  use StreamixWeb, :live_view

  import StreamixWeb.AppComponents
  import StreamixWeb.ContentComponents
  import StreamixWeb.CoreComponents, only: [icon: 1]

  alias Streamix.Iptv

  @per_page 24

  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    animes_count = Iptv.count_gindex_animes()

    socket =
      socket
      |> assign(user_id: user_id)
      |> assign(search: "")
      |> assign(page: 1)
      |> assign(has_more: true)
      |> assign(loading: false)
      |> assign(favorites_map: MapSet.new())
      |> assign(empty_results: false)
      |> assign(page_title: "Animes - GDrive")
      |> assign(current_path: "/browse/animes")
      |> assign(animes_count: animes_count)
      |> stream(:animes, [])

    {:ok, socket}
  end

  def handle_params(params, _url, socket) do
    search = params["search"] || ""

    socket =
      socket
      |> assign(search: search)
      |> assign(page: 1)
      |> stream(:animes, [], reset: true)
      |> load_animes()
      |> load_favorites_map()

    {:noreply, socket}
  end

  # ============================================
  # Event Handlers
  # ============================================

  def handle_event("search", %{"search" => search}, socket) do
    path =
      if search == "",
        do: ~p"/browse/animes?source=gindex",
        else: ~p"/browse/animes?source=gindex&search=#{search}"

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("load_more", _, socket) do
    socket =
      socket
      |> assign(page: socket.assigns.page + 1)
      |> assign(loading: true)
      |> load_animes()

    {:noreply, socket}
  end

  def handle_event("view_series", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/gindex/animes/#{id}")}
  end

  def handle_event("toggle_favorite", %{"id" => id, "type" => "series"}, socket) do
    user_id = socket.assigns.user_id
    anime_id = String.to_integer(id)
    anime = Iptv.get_series!(anime_id)
    is_favorite = MapSet.member?(socket.assigns.favorites_map, anime_id)

    if is_favorite do
      Iptv.remove_favorite(user_id, "series", anime_id)
    else
      Iptv.add_favorite(user_id, %{
        content_type: "series",
        content_id: anime_id,
        content_name: anime.title || anime.name,
        content_icon: anime.cover
      })
    end

    favorites_map =
      if is_favorite do
        MapSet.delete(socket.assigns.favorites_map, anime_id)
      else
        MapSet.put(socket.assigns.favorites_map, anime_id)
      end

    {:noreply,
     socket
     |> assign(favorites_map: favorites_map)
     |> stream_insert(:animes, anime)}
  end

  # ============================================
  # Render
  # ============================================

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-col gap-4">
        <%!-- Source and content tabs row --%>
        <div class="flex flex-wrap items-center gap-3">
          <.source_tabs selected="gindex" path="/browse/animes" gindex_path="/browse/animes" />
          <div class="hidden sm:block w-px h-8 bg-border" />
          <.browse_tabs
            selected={:animes}
            source="gindex"
            counts={%{animes: @animes_count, movies: 0, series: 0}}
          />
        </div>

        <%!-- Filters row --%>
        <div class="flex flex-wrap items-center gap-3">
          <.search_input value={@search} placeholder="Buscar animes..." />
        </div>
      </div>

      <div
        id="animes"
        phx-update="stream"
        class="grid gap-4 grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6"
      >
        <div :for={{dom_id, anime} <- @streams.animes} id={dom_id}>
          <.anime_card
            anime={anime}
            is_favorite={MapSet.member?(@favorites_map, anime.id)}
          />
        </div>
      </div>

      <.empty_state
        :if={@empty_results && !@loading}
        icon="hero-sparkles"
        title="Nenhum anime encontrado"
        message="Tente ajustar os filtros ou fazer uma busca diferente."
      />

      <.infinite_scroll has_more={@has_more} loading={@loading} />
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp load_animes(socket) do
    search = socket.assigns.search
    page = socket.assigns.page

    animes =
      Iptv.list_gindex_animes(
        search: search,
        limit: @per_page,
        offset: (page - 1) * @per_page
      )

    has_more = length(animes) >= @per_page
    empty_results = page == 1 && Enum.empty?(animes)

    socket
    |> stream(:animes, animes)
    |> assign(has_more: has_more)
    |> assign(loading: false)
    |> assign(empty_results: empty_results)
  end

  defp load_favorites_map(socket) do
    user_id = socket.assigns.user_id
    favorite_ids = Iptv.list_favorite_ids(user_id, "series")
    assign(socket, favorites_map: favorite_ids)
  end

  # Anime card component (custom for animes)
  defp anime_card(assigns) do
    ~H"""
    <div class="bg-surface rounded-lg overflow-hidden hover:ring-2 hover:ring-purple-500/50 transition-all group cursor-pointer">
      <div
        class="relative aspect-[2/3] bg-surface-hover overflow-hidden"
        phx-click="view_series"
        phx-value-id={@anime.id}
      >
        <div class="w-full h-full flex items-center justify-center bg-gradient-to-br from-purple-900/50 to-gray-900">
          <.icon name="hero-sparkles" class="size-16 text-purple-400/30" />
        </div>

        <span class="absolute top-2 right-2 px-1.5 py-0.5 text-[10px] font-bold rounded bg-purple-600/90 text-white">
          GDrive
        </span>

        <div
          :if={@anime.episode_count && @anime.episode_count > 0}
          class="absolute bottom-2 left-2 px-2 py-0.5 text-xs rounded bg-purple-600 text-white"
        >
          {@anime.episode_count} eps
        </div>
      </div>

      <div class="p-3">
        <div class="flex items-start justify-between gap-2">
          <div class="min-w-0 flex-1">
            <h3 class="font-medium text-sm text-text-primary truncate" title={@anime.name}>
              {@anime.title || @anime.name}
            </h3>
            <p :if={@anime.year} class="text-xs text-text-secondary">
              {@anime.year}
              <span :if={@anime.season_count && @anime.season_count > 0}>
                | {pluralize(@anime.season_count, "release", "releases")}
              </span>
            </p>
          </div>
          <button
            type="button"
            phx-click="toggle_favorite"
            phx-value-id={@anime.id}
            phx-value-type="series"
            class="flex-shrink-0 p-1 hover:scale-110 transition-transform"
          >
            <.icon
              name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"}
              class={["size-5", @is_favorite && "text-red-500"]}
            />
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp pluralize(1, singular, _plural), do: "1 #{singular}"
  defp pluralize(count, _singular, plural), do: "#{count} #{plural}"
end
