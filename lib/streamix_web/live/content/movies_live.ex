defmodule StreamixWeb.Content.MoviesLive do
  @moduledoc """
  LiveView for browsing movies from a provider.
  Works for both /browse/movies (global provider) and /providers/:id/movies (user provider).
  Supports source=gindex param for GIndex content.
  """
  use StreamixWeb, :live_view

  import StreamixWeb.AppComponents
  import StreamixWeb.ContentComponents

  alias Streamix.Iptv

  @per_page 24

  # Mount for /browse/movies (global provider or gindex)
  def mount(%{}, _session, socket) when not is_map_key(socket.assigns, :provider) do
    user_id = socket.assigns.current_scope.user.id
    user = socket.assigns.current_scope.user

    # Source will be set in handle_params
    socket =
      socket
      |> assign(user_id: user_id)
      |> assign(user: user)
      |> assign(mode: :browse)
      |> assign(source: "iptv")
      |> assign(provider: nil)
      |> assign(categories: [])
      |> assign(selected_category: nil)
      |> assign(search: "")
      |> assign(page: 1)
      |> assign(has_more: true)
      |> assign(loading: false)
      |> assign(favorites_map: %{})
      |> assign(empty_results: false)
      |> assign(page_title: "Filmes")
      |> assign(current_path: "/browse/movies")
      |> assign(gindex_count: 0)
      |> stream(:movies, [])

    {:ok, socket}
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
    user = socket.assigns.current_scope.user
    categories = Iptv.list_categories(provider.id, "vod")
    categories = filter_adult_categories(categories, user.show_adult_content)

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
      |> assign(source: "iptv")
      |> assign(categories: categories)
      |> assign(selected_category: nil)
      |> assign(search: "")
      |> assign(page: 1)
      |> assign(has_more: true)
      |> assign(loading: false)
      |> assign(favorites_map: %{})
      |> assign(empty_results: false)
      |> assign(user_id: user_id)
      |> assign(user: user)
      |> assign(gindex_count: 0)
      |> stream(:movies, [])
      |> load_movies()
      |> load_favorites_map()

    {:ok, socket}
  end

  def handle_params(params, _url, socket) do
    source = params["source"] || "iptv"
    category = parse_integer_param(params["category"])
    search = params["search"] || ""

    socket =
      socket
      |> assign(source: source)
      |> assign(selected_category: category)
      |> assign(search: search)
      |> assign(page: 1)
      |> stream(:movies, [], reset: true)
      |> maybe_reload_provider_and_categories(source)
      |> load_movies()
      |> load_favorites_map()

    {:noreply, socket}
  end

  defp maybe_reload_provider_and_categories(socket, source) do
    # We re-assign source in handle_params, so we should check against the
    # *previous* source if we had it, but here we've already assigned the
    # new source.
    # Actually, the logic in original code checked `socket.assigns.source`
    # before assignment?
    # No, it did: `source_changed = socket.assigns.source != source`.
    # But in my refactor, I passed `source` to this function. I need to handle
    # the condition correctly.
    # Since I'm assigning `source` before calling this, `socket.assigns.source`
    # is already `source`.
    # Wait, `assign/3` returns a *new* socket struct.
    # So if I chain `assign(source: source) |> maybe_reload...`, the socket
    # passed to `maybe_reload` *has* the new source.
    # So `socket.assigns.source != source` would always be false if I use the
    # new socket.
    #
    # Original logic:
    # `source_changed = socket.assigns.source != source` (OLD socket vs NEW source param)
    #
    # So I should check if I need to reload based on the socket state *before*
    # it was potentially cleared?
    # Actually, the requirement is: "When source changes or on initial load
    # (provider nil), reload everything".
    #
    # If I simply check `socket.assigns.provider == nil` or if the provider
    # type doesn't match the source?
    #
    # Let's look at the original logic again:
    # `needs_provider_load = source_changed || (source == "iptv" && socket.assigns.provider == nil)`
    #
    # I can just implement `reload_provider_if_needed(socket)`.
    # It checks `socket.assigns.source`.
    #
    # If source is "gindex" and provider is NOT nil (or we don't have gindex info), we load.
    # If source is "iptv" and provider is nil, we load.
    #
    # Simpler approach: blindly reload if conditions met.
    #
    # Let's stick to the original logic but extracted.
    # But I can't easily access the "old" source if I've already updated the socket.
    #
    # Solution: Do the check *before* the chain? Or inside the function, checking if the current state
    # matches the source.
    #
    # If source="gindex", we expect provider=nil. If provider!=nil, we need to reload (clear it).
    # If source="iptv", we expect provider!=nil. If provider==nil, we need to reload.
    #
    # That seems robust enough.

    case source do
      "gindex" ->
        # If we have a provider, it means we were in IPTV mode, so switch.
        # Or if we just want to ensure GIndex state is correct.
        if socket.assigns.provider != nil or socket.assigns.gindex_count == 0 do
          load_gindex_provider(socket)
        else
          socket
        end

      "iptv" ->
        # If we don't have a provider, we need to load it.
        if socket.assigns.provider == nil do
          load_iptv_provider(socket)
        else
          socket
        end

      _ ->
        socket
    end
  end

  defp load_gindex_provider(socket) do
    gindex_counts = Iptv.gindex_counts()

    socket
    |> assign(provider: nil)
    |> assign(categories: [])
    |> assign(page_title: "Filmes - GDrive")
    |> assign(gindex_counts: gindex_counts)
  end

  defp load_iptv_provider(socket) do
    user = socket.assigns.user
    provider = Iptv.get_global_provider()

    if provider do
      categories = Iptv.list_categories(provider.id, "vod")
      categories = filter_adult_categories(categories, user.show_adult_content)

      socket
      |> assign(provider: provider)
      |> assign(categories: categories)
      |> assign(page_title: "Filmes")
      |> assign(gindex_counts: Iptv.gindex_counts())
    else
      socket
      |> assign(provider: nil)
      |> assign(categories: [])
      |> assign(page_title: "Filmes")
      |> assign(gindex_counts: Iptv.gindex_counts())
    end
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
      <div class="flex flex-col gap-4">
        <%!-- Source and content tabs row --%>
        <div class="flex flex-wrap items-center gap-3">
          <%= if @mode == :browse do %>
            <.source_tabs selected={@source} path="/browse/movies" />
            <div class="hidden sm:block w-px h-8 bg-border" />
            <.browse_tabs
              selected={:movies}
              source={@source}
              counts={get_counts(assigns)}
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
        </div>

        <%!-- Filters row --%>
        <div class="flex flex-wrap items-center gap-3">
          <.category_filter_v2
            :if={@source == "iptv" && length(@categories) > 0}
            categories={@categories}
            selected={@selected_category}
          />
          <.search_input value={@search} placeholder="Buscar filmes..." />
        </div>
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
            source={@source}
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

  defp get_counts(%{source: "gindex", gindex_counts: counts}) do
    %{live: 0, movies: counts.movies, series: counts.series, animes: counts.animes}
  end

  # Fallback for old gindex_count format
  defp get_counts(%{source: "gindex", gindex_count: count}) do
    %{live: 0, movies: count, series: 0, animes: 0}
  end

  defp get_counts(%{provider: nil}) do
    %{live: 0, movies: 0, series: 0}
  end

  defp get_counts(%{provider: provider}) do
    %{
      live: provider.live_channels_count,
      movies: provider.movies_count,
      series: provider.series_count
    }
  end

  defp load_movies(%{assigns: %{source: "gindex"}} = socket) do
    user = socket.assigns.user
    search = socket.assigns.search
    page = socket.assigns.page

    movies =
      Iptv.list_gindex_movies(
        search: search,
        limit: @per_page,
        offset: (page - 1) * @per_page,
        show_adult: user.show_adult_content
      )

    has_more = length(movies) >= @per_page
    empty_results = page == 1 && Enum.empty?(movies)

    socket
    |> stream(:movies, movies)
    |> assign(has_more: has_more)
    |> assign(loading: false)
    |> assign(empty_results: empty_results)
  end

  defp load_movies(%{assigns: %{provider: nil}} = socket) do
    socket
    |> assign(has_more: false)
    |> assign(loading: false)
    |> assign(empty_results: true)
  end

  defp load_movies(socket) do
    user = socket.assigns.user
    provider_id = socket.assigns.provider.id
    category = socket.assigns.selected_category
    search = socket.assigns.search
    page = socket.assigns.page

    movies =
      Iptv.list_movies(provider_id,
        category_id: category,
        search: search,
        limit: @per_page,
        offset: (page - 1) * @per_page,
        show_adult: user.show_adult_content
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

  defp filter_adult_categories(categories, true), do: categories
  defp filter_adult_categories(categories, _), do: Enum.reject(categories, & &1.is_adult)

  # Path builders based on mode and source
  defp build_path(%{assigns: %{mode: :browse, source: source}}, nil, "") do
    case source do
      "gindex" -> ~p"/browse/movies?source=gindex"
      _ -> ~p"/browse/movies"
    end
  end

  defp build_path(%{assigns: %{mode: :browse, source: source}}, nil, search) do
    case source do
      "gindex" -> ~p"/browse/movies?source=gindex&search=#{search}"
      _ -> ~p"/browse/movies?search=#{search}"
    end
  end

  defp build_path(%{assigns: %{mode: :browse, source: source}}, category, "") do
    case source do
      "gindex" -> ~p"/browse/movies?source=gindex&category=#{category}"
      _ -> ~p"/browse/movies?category=#{category}"
    end
  end

  defp build_path(%{assigns: %{mode: :browse, source: source}}, category, search) do
    case source do
      "gindex" -> ~p"/browse/movies?source=gindex&category=#{category}&search=#{search}"
      _ -> ~p"/browse/movies?category=#{category}&search=#{search}"
    end
  end

  defp build_path(%{assigns: %{mode: :provider, provider: provider}}, nil, ""),
    do: ~p"/providers/#{provider.id}/movies"

  defp build_path(%{assigns: %{mode: :provider, provider: provider}}, nil, search),
    do: ~p"/providers/#{provider.id}/movies?search=#{search}"

  defp build_path(%{assigns: %{mode: :provider, provider: provider}}, category, ""),
    do: ~p"/providers/#{provider.id}/movies?category=#{category}"

  defp build_path(%{assigns: %{mode: :provider, provider: provider}}, category, search),
    do: ~p"/providers/#{provider.id}/movies?category=#{category}&search=#{search}"

  # Detail path based on source
  defp detail_path(%{assigns: %{source: "gindex"}}, id), do: ~p"/gindex/movies/#{id}"
  defp detail_path(%{assigns: %{mode: :browse}}, id), do: ~p"/browse/movies/#{id}"

  defp detail_path(%{assigns: %{mode: :provider, provider: provider}}, id),
    do: ~p"/providers/#{provider.id}/movies/#{id}"
end
