defmodule StreamixWeb.Content.MoviesLive do
  @moduledoc """
  LiveView for browsing movies from a provider.
  Works for both /browse/movies (global provider) and /providers/:id/movies (user provider).
  """
  use StreamixWeb, :live_view

  import StreamixWeb.AppComponents
  import StreamixWeb.ContentComponents

  alias Streamix.Iptv

  @per_page 24

  # Mount for /browse/movies (global provider)
  def mount(%{}, _session, socket) when not is_map_key(socket.assigns, :provider) do
    user_id = socket.assigns.current_scope.user.id
    provider = Iptv.get_global_provider()

    if provider do
      mount_with_provider(socket, provider, user_id, :browse)
    else
      {:ok,
       socket
       |> put_flash(:error, "Catálogo não disponível. Configure um provedor.")
       |> push_navigate(to: ~p"/providers")}
    end
  end

  # Mount for /providers/:provider_id/movies (user provider)
  def mount(%{"provider_id" => provider_id}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    provider = Iptv.get_playable_provider(user_id, provider_id)

    if provider do
      mount_with_provider(socket, provider, user_id, :provider)
    else
      {:ok,
       socket
       |> put_flash(:error, "Provedor não encontrado")
       |> push_navigate(to: ~p"/providers")}
    end
  end

  defp mount_with_provider(socket, provider, user_id, mode) do
    categories = Iptv.list_categories(provider.id, "vod")

    current_path =
      if mode == :browse,
        do: "/browse/movies",
        else: "/providers/#{provider.id}/movies"

    page_title =
      if mode == :browse,
        do: "Filmes",
        else: "Filmes - #{provider.name}"

    socket =
      socket
      |> assign(page_title: page_title)
      |> assign(current_path: current_path)
      |> assign(provider: provider)
      |> assign(mode: mode)
      |> assign(categories: categories)
      |> assign(selected_category: nil)
      |> assign(search: "")
      |> assign(page: 1)
      |> assign(has_more: true)
      |> assign(loading: false)
      |> assign(favorites_map: %{})
      |> assign(empty_results: false)
      |> assign(user_id: user_id)
      |> stream(:movies, [])
      |> load_movies()
      |> load_favorites_map()

    {:ok, socket}
  end

  def handle_params(params, _url, socket) do
    category = parse_integer_param(params["category"])
    search = params["search"] || ""

    socket =
      socket
      |> assign(selected_category: category)
      |> assign(search: search)
      |> assign(page: 1)
      |> stream(:movies, [], reset: true)
      |> load_movies()

    {:noreply, socket}
  end

  defp parse_integer_param(nil), do: nil
  defp parse_integer_param(""), do: nil
  defp parse_integer_param(value) when is_binary(value), do: String.to_integer(value)
  defp parse_integer_param(value), do: value

  # ============================================
  # Event Handlers
  # ============================================

  def handle_event("filter_category", %{"category" => category}, socket) do
    category = if category == "", do: nil, else: category
    {:noreply, push_patch(socket, to: build_path(socket, category, socket.assigns.search))}
  end

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply,
     push_patch(socket, to: build_path(socket, socket.assigns.selected_category, search))}
  end

  def handle_event("load_more", _, socket) do
    socket =
      socket
      |> assign(page: socket.assigns.page + 1)
      |> assign(loading: true)
      |> load_movies()

    {:noreply, socket}
  end

  def handle_event("play_movie", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: detail_path(socket, id))}
  end

  def handle_event("show_details", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: detail_path(socket, id))}
  end

  def handle_event("toggle_favorite", %{"id" => id, "type" => "movie"}, socket) do
    user_id = socket.assigns.user_id
    movie_id = String.to_integer(id)
    movie = Iptv.get_movie!(movie_id)
    is_favorite = MapSet.member?(socket.assigns.favorites_map, movie_id)

    if is_favorite do
      Iptv.remove_favorite(user_id, "movie", movie_id)
    else
      Iptv.add_favorite(user_id, %{
        content_type: "movie",
        content_id: movie_id,
        content_name: movie.title || movie.name,
        content_icon: movie.stream_icon
      })
    end

    # Toggle in MapSet
    favorites_map =
      if is_favorite do
        MapSet.delete(socket.assigns.favorites_map, movie_id)
      else
        MapSet.put(socket.assigns.favorites_map, movie_id)
      end

    {:noreply,
     socket
     |> assign(favorites_map: favorites_map)
     |> stream_insert(:movies, movie)}
  end

  # ============================================
  # Render
  # ============================================

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-wrap items-center gap-4">
        <%= if @mode == :browse do %>
          <.browse_tabs
            selected={:movies}
            counts={
              %{
                live: @provider.live_channels_count,
                movies: @provider.movies_count,
                series: @provider.series_count
              }
            }
          />
        <% else %>
          <.content_tabs
            selected={:movies}
            provider_id={@provider.id}
            counts={
              %{
                live: @provider.live_channels_count,
                movies: @provider.movies_count,
                series: @provider.series_count
              }
            }
          />
        <% end %>

        <.category_filter_v2 categories={@categories} selected={@selected_category} />
        <.search_input value={@search} placeholder="Buscar filmes..." />
      </div>

      <div
        id="movies"
        phx-update="stream"
        class="grid gap-4 grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6"
      >
        <div :for={{dom_id, movie} <- @streams.movies} id={dom_id}>
          <.movie_card
            movie={movie}
            is_favorite={MapSet.member?(@favorites_map, movie.id)}
          />
        </div>
      </div>

      <.empty_state
        :if={@empty_results && !@loading}
        icon="hero-film"
        title="Nenhum filme encontrado"
        message="Tente ajustar os filtros ou fazer uma busca diferente."
      />

      <.infinite_scroll has_more={@has_more} loading={@loading} />
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp load_movies(socket) do
    provider_id = socket.assigns.provider.id
    category = socket.assigns.selected_category
    search = socket.assigns.search
    page = socket.assigns.page

    movies =
      Iptv.list_movies(provider_id,
        category_id: category,
        search: search,
        limit: @per_page,
        offset: (page - 1) * @per_page
      )

    has_more = length(movies) >= @per_page
    empty_results = page == 1 && Enum.empty?(movies)

    socket
    |> stream(:movies, movies)
    |> assign(has_more: has_more)
    |> assign(loading: false)
    |> assign(empty_results: empty_results)
  end

  defp load_favorites_map(socket) do
    user_id = socket.assigns.user_id
    # Optimized: only fetches content_ids instead of full records
    favorite_ids = Iptv.list_favorite_ids(user_id, "movie")
    assign(socket, favorites_map: favorite_ids)
  end

  # Path builders based on mode
  defp build_path(%{assigns: %{mode: :browse}}, nil, ""), do: ~p"/browse/movies"

  defp build_path(%{assigns: %{mode: :browse}}, nil, search),
    do: ~p"/browse/movies?search=#{search}"

  defp build_path(%{assigns: %{mode: :browse}}, category, ""),
    do: ~p"/browse/movies?category=#{category}"

  defp build_path(%{assigns: %{mode: :browse}}, category, search),
    do: ~p"/browse/movies?category=#{category}&search=#{search}"

  defp build_path(%{assigns: %{mode: :provider, provider: provider}}, nil, ""),
    do: ~p"/providers/#{provider.id}/movies"

  defp build_path(%{assigns: %{mode: :provider, provider: provider}}, nil, search),
    do: ~p"/providers/#{provider.id}/movies?search=#{search}"

  defp build_path(%{assigns: %{mode: :provider, provider: provider}}, category, ""),
    do: ~p"/providers/#{provider.id}/movies?category=#{category}"

  defp build_path(%{assigns: %{mode: :provider, provider: provider}}, category, search),
    do: ~p"/providers/#{provider.id}/movies?category=#{category}&search=#{search}"

  defp detail_path(%{assigns: %{mode: :browse}}, id), do: ~p"/browse/movies/#{id}"

  defp detail_path(%{assigns: %{mode: :provider, provider: provider}}, id),
    do: ~p"/providers/#{provider.id}/movies/#{id}"
end
