defmodule StreamixWeb.Content.SeriesLive do
  @moduledoc """
  LiveView for browsing series from a provider.

  Features:
  - Grid display with series cards
  - Category filtering
  - Search functionality
  - Infinite scroll pagination
  - Favorites management
  """
  use StreamixWeb, :live_view

  import StreamixWeb.AppComponents
  import StreamixWeb.ContentComponents

  alias Streamix.Iptv

  @per_page 24

  @doc false
  def mount(%{"provider_id" => provider_id}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    provider = Iptv.get_user_provider(user_id, provider_id)

    if provider do
      categories = Iptv.list_categories(provider.id, "series")

      socket =
        socket
        |> assign(page_title: "Séries - #{provider.name}")
        |> assign(current_path: "/providers/#{provider_id}/series")
        |> assign(provider: provider)
        |> assign(categories: categories)
        |> assign(selected_category: nil)
        |> assign(search: "")
        |> assign(page: 1)
        |> assign(has_more: true)
        |> assign(loading: false)
        |> assign(favorites_map: %{})
        |> stream(:series, [])
        |> load_series()
        |> load_favorites_map()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Provedor não encontrado")
       |> push_navigate(to: ~p"/providers")}
    end
  end

  @doc false
  def handle_params(params, _url, socket) do
    category = params["category"]
    search = params["search"] || ""

    socket =
      socket
      |> assign(selected_category: category)
      |> assign(search: search)
      |> assign(page: 1)
      |> stream(:series, [], reset: true)
      |> load_series()

    {:noreply, socket}
  end

  # ============================================
  # Event Handlers
  # ============================================

  @doc false
  def handle_event("filter_category", %{"category" => category}, socket) do
    category = if category == "", do: nil, else: category
    provider_id = socket.assigns.provider.id

    {:noreply, push_patch(socket, to: build_path(provider_id, category, socket.assigns.search))}
  end

  def handle_event("search", %{"search" => search}, socket) do
    provider_id = socket.assigns.provider.id

    {:noreply,
     push_patch(socket, to: build_path(provider_id, socket.assigns.selected_category, search))}
  end

  def handle_event("load_more", _, socket) do
    socket =
      socket
      |> assign(page: socket.assigns.page + 1)
      |> assign(loading: true)
      |> load_series()

    {:noreply, socket}
  end

  def handle_event("view_series", %{"id" => id}, socket) do
    provider_id = socket.assigns.provider.id
    {:noreply, push_navigate(socket, to: ~p"/providers/#{provider_id}/series/#{id}")}
  end

  def handle_event("toggle_favorite", %{"id" => id, "type" => "series"}, socket) do
    user_id = socket.assigns.current_scope.user.id
    series_id = String.to_integer(id)
    is_favorite = Map.get(socket.assigns.favorites_map, series_id, false)

    if is_favorite do
      Iptv.remove_favorite(user_id, "series", series_id)
    else
      series = Iptv.get_series!(series_id)

      Iptv.add_favorite(user_id, %{
        content_type: "series",
        content_id: series_id,
        content_name: series.title || series.name,
        content_icon: series.cover
      })
    end

    favorites_map = Map.put(socket.assigns.favorites_map, series_id, !is_favorite)
    {:noreply, assign(socket, favorites_map: favorites_map)}
  end

  # ============================================
  # Render
  # ============================================

  @doc false
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.content_tabs
        selected={:series}
        provider_id={@provider.id}
        counts={
          %{
            live: @provider.live_count,
            movies: @provider.movies_count,
            series: @provider.series_count
          }
        }
      />

      <div class="flex flex-wrap items-center gap-4">
        <.category_filter_v2 categories={@categories} selected={@selected_category} />
        <.search_input value={@search} placeholder="Buscar séries..." />
      </div>

      <div
        id="series"
        phx-update="stream"
        class="grid gap-4 grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6"
      >
        <div :for={{dom_id, series} <- @streams.series} id={dom_id}>
          <.series_card
            series={series}
            is_favorite={Map.get(@favorites_map, series.id, false)}
          />
        </div>
      </div>

      <.empty_state
        :if={@page == 1 && !@loading && Enum.empty?(@streams.series)}
        icon="hero-video-camera"
        title="Nenhuma série encontrada"
        message="Tente ajustar os filtros ou fazer uma busca diferente."
      />

      <.infinite_scroll has_more={@has_more} loading={@loading} />
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp load_series(socket) do
    provider_id = socket.assigns.provider.id
    category = socket.assigns.selected_category
    search = socket.assigns.search
    page = socket.assigns.page

    series =
      Iptv.list_series(provider_id,
        category_id: category,
        search: search,
        limit: @per_page,
        offset: (page - 1) * @per_page
      )

    has_more = length(series) >= @per_page

    socket
    |> stream(:series, series)
    |> assign(has_more: has_more)
    |> assign(loading: false)
  end

  defp load_favorites_map(socket) do
    user_id = socket.assigns.current_scope.user.id

    favorites =
      Iptv.list_favorites(user_id, content_type: "series")
      |> Enum.map(& &1.content_id)
      |> Enum.into(%{}, fn id -> {id, true} end)

    assign(socket, favorites_map: favorites)
  end

  defp build_path(provider_id, nil, ""), do: ~p"/providers/#{provider_id}/series"

  defp build_path(provider_id, nil, search),
    do: ~p"/providers/#{provider_id}/series?search=#{search}"

  defp build_path(provider_id, category, ""),
    do: ~p"/providers/#{provider_id}/series?category=#{category}"

  defp build_path(provider_id, category, search),
    do: ~p"/providers/#{provider_id}/series?category=#{category}&search=#{search}"
end
