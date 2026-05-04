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
    gindex_counts = Iptv.gindex_counts()

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
      |> assign(gindex_counts: gindex_counts)
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

  # ThemeToggle hook event (client-side theme management, no server action needed)
  def handle_event("theme_init", _params, socket), do: {:noreply, socket}

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

    case parse_positive_integer(id) do
      {:ok, anime_id} ->
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

      :error ->
        {:noreply, socket}
    end
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> :error
    end
  end

  defp parse_positive_integer(_), do: :error

  # ============================================
  # Render
  # ============================================

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="browse-toolbar">
        <%!-- Source and content tabs row --%>
        <div class="browse-toolbar__row">
          <.source_tabs
            selected="gindex"
            path="/browse/animes"
            iptv_path="/browse"
            gindex_path="/browse/animes"
          />
          <div class="browse-toolbar__divider" />
          <.browse_tabs selected={:animes} source="gindex" counts={@gindex_counts} />
          <.search_input
            value={@search}
            placeholder="Buscar animes..."
            class="browse-toolbar__search"
          />
        </div>
      </div>

      <div
        id="animes"
        phx-update="stream"
        class="grid gap-4 grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6"
      >
        <div :for={{dom_id, anime} <- @streams.animes} id={dom_id}>
          <.series_card
            series={anime}
            source="gindex"
            is_favorite={MapSet.member?(@favorites_map, anime.id)}
          />
        </div>
      </div>
      
    <!-- Infinite Scroll Sentinel -->
      <div
        :if={@has_more && !@loading}
        id="animes-sentinel"
        phx-hook="InfiniteScroll"
        data-page={@page}
        class="h-4"
      />

      <div :if={@loading} class="flex justify-center py-8">
        <.icon name="hero-arrow-path" class="size-8 text-brand animate-spin" />
      </div>

      <.empty_state
        :if={@empty_results && !@loading}
        icon="hero-sparkles"
        title="Nenhum anime encontrado"
        message="Tente ajustar os filtros ou fazer uma busca diferente."
      />
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
end
