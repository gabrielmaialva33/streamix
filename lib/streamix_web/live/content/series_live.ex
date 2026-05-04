defmodule StreamixWeb.Content.SeriesLive do
  @moduledoc """
  LiveView for browsing series from a provider.
  Works for both /browse/series (global provider) and /providers/:id/series (user provider).
  Supports source=gindex param for GIndex content.
  """
  use StreamixWeb, :live_view

  import StreamixWeb.AppComponents
  import StreamixWeb.ContentComponents

  alias Streamix.Access
  alias Streamix.Iptv

  @per_page 24

  # Mount for /browse/series (global provider or gindex)
  def mount(%{}, _session, socket) when not is_map_key(socket.assigns, :provider) do
    user_id = socket.assigns.current_scope.user.id
    user = socket.assigns.current_scope.user

    # Source will be set in handle_params
    socket =
      socket
      |> assign(user_id: user_id)
      |> assign(user: user)
      |> assign(premium_access: premium_access?(user))
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
      |> assign(page_title: "Séries")
      |> assign(current_path: "/browse/series")
      |> assign(gindex_count: 0)
      |> assign(sort: nil)
      |> stream(:series, [])

    {:ok, socket}
  end

  def handle_params(params, _url, socket) do
    source = params["source"] || "iptv"
    category = parse_integer_param(params["category"])
    search = params["search"] || ""
    sort = parse_sort_param(params["sort"])

    case apply_route_context(socket, params, source) do
      {:ok, socket} ->
        socket =
          socket
          |> assign(selected_category: category)
          |> assign(search: search)
          |> assign(sort: sort)
          |> assign(page: 1)
          |> stream(:series, [], reset: true)
          |> load_series()
          |> load_favorites_map()

        {:noreply, socket}

      {:redirect, socket} ->
        {:noreply, socket}
    end
  end

  defp parse_sort_param(sort) when sort in ["popularity", "rating"], do: sort
  defp parse_sort_param(_), do: nil

  defp apply_route_context(socket, %{"provider_id" => provider_id}, _source) do
    provider = Iptv.get_playable_provider(socket.assigns.user_id, provider_id)

    if provider do
      user = socket.assigns.user
      categories = Iptv.list_categories(provider.id, "series")
      categories = filter_adult_categories(categories, user.show_adult_content)

      {:ok,
       socket
       |> assign(page_title: "Séries - #{provider.name}")
       |> assign(current_path: "/providers/#{provider.id}/series")
       |> assign(provider: provider)
       |> assign(mode: :provider)
       |> assign(source: "iptv")
       |> assign(categories: categories)
       |> assign(gindex_counts: Iptv.gindex_counts())}
    else
      {:redirect,
       socket
       |> put_flash(:error, "Provedor não encontrado")
       |> push_navigate(to: ~p"/providers")}
    end
  end

  defp apply_route_context(socket, _params, "gindex") do
    {:ok,
     socket
     |> assign(page_title: "Séries - GDrive")
     |> assign(current_path: "/browse/series")
     |> assign(provider: nil)
     |> assign(mode: :browse)
     |> assign(source: "gindex")
     |> assign(categories: [])
     |> assign(gindex_counts: Iptv.gindex_counts())}
  end

  defp apply_route_context(socket, _params, _source) do
    user = socket.assigns.user
    provider = Iptv.get_global_provider()

    categories =
      case provider do
        nil -> []
        provider -> Iptv.list_categories(provider.id, "series")
      end

    categories = filter_adult_categories(categories, user.show_adult_content)

    {:ok,
     socket
     |> assign(page_title: "Séries")
     |> assign(current_path: "/browse/series")
     |> assign(provider: provider)
     |> assign(mode: :browse)
     |> assign(source: "iptv")
     |> assign(categories: categories)
     |> assign(gindex_counts: Iptv.gindex_counts())}
  end

  defp parse_integer_param(nil), do: nil
  defp parse_integer_param(""), do: nil

  defp parse_integer_param(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_integer_param(value), do: value

  # ============================================
  # Event Handlers
  # ============================================

  # ThemeToggle hook event (client-side theme management, no server action needed)
  def handle_event("theme_init", _params, socket), do: {:noreply, socket}

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
      |> load_series()

    {:noreply, socket}
  end

  def handle_event("view_series", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: detail_path(socket, id))}
  end

  def handle_event("toggle_favorite", %{"id" => id, "type" => "series"}, socket) do
    user_id = socket.assigns.user_id
    series_id = parse_integer_param(id)

    if is_nil(series_id) do
      {:noreply, socket}
    else
      series = Iptv.get_series!(series_id)
      is_favorite = MapSet.member?(socket.assigns.favorites_map, series_id)

      if is_favorite do
        Iptv.remove_favorite(user_id, "series", series_id)
      else
        Iptv.add_favorite(user_id, %{
          content_type: "series",
          content_id: series_id,
          content_name: series.title || series.name,
          content_icon: series.cover
        })
      end

      # Toggle in MapSet
      favorites_map =
        if is_favorite do
          MapSet.delete(socket.assigns.favorites_map, series_id)
        else
          MapSet.put(socket.assigns.favorites_map, series_id)
        end

      {:noreply,
       socket
       |> assign(favorites_map: favorites_map)
       |> stream_insert(:series, series)}
    end
  end

  # ============================================
  # Render
  # ============================================

  def render(assigns) do
    ~H"""
    <div class="space-y-4 sm:space-y-5">
      <div class="browse-toolbar">
        <%!-- Row 1: Source toggle + Content tabs --%>
        <div class="browse-toolbar__row">
          <%= if @mode == :browse do %>
            <.source_tabs selected={@source} path="/browse/series" />
            <div class="browse-toolbar__divider" />
            <.browse_tabs
              selected={:series}
              source={@source}
              counts={get_counts(assigns)}
            />
          <% else %>
            <.content_tabs
              selected={:series}
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

          <.search_input
            value={@search}
            placeholder="Buscar séries..."
            class="browse-toolbar__search"
          />
        </div>

        <.premium_cta_banner
          :if={@mode == :browse and @source == "iptv" and not @premium_access}
          id="browse-premium-cta"
          current_scope={@current_scope}
        />
      </div>

      <div class="flex flex-col sm:flex-row gap-4 sm:gap-6">
        <.category_filter_v2
          :if={@source == "iptv" && length(@categories) > 0}
          categories={@categories}
          selected={@selected_category}
          layout={:sidebar}
        />
        <div class="flex-1 min-w-0">
          <div
            id="series"
            phx-update="stream"
            class="responsive-poster-grid"
          >
            <div :for={{dom_id, series} <- @streams.series} id={dom_id}>
              <.series_card
                series={series}
                is_favorite={MapSet.member?(@favorites_map, series.id)}
                source={@source}
                show_premium_badge={@mode == :browse and @source == "iptv" and not @premium_access}
              />
            </div>
          </div>
          
    <!-- Infinite Scroll Sentinel -->
          <div
            :if={@has_more && !@loading}
            id="series-sentinel"
            phx-hook="InfiniteScroll"
            data-page={@page}
            class="h-4"
          />

          <div
            :if={@loading}
            class="responsive-poster-grid"
          >
            <.skeleton_card :for={_ <- 1..12} />
          </div>

          <.empty_state
            :if={@empty_results && !@loading}
            icon="hero-video-camera"
            title="Nenhuma série encontrada"
            message="Tente ajustar os filtros ou fazer uma busca diferente."
          />
        </div>
      </div>
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
    %{live: 0, movies: 0, series: count, animes: 0}
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

  defp premium_access?(user) do
    Access.can_play_global_content?(user, Iptv.get_global_provider())
  end

  defp load_series(%{assigns: %{source: "gindex"}} = socket) do
    search = socket.assigns.search
    page = socket.assigns.page

    series =
      Iptv.list_gindex_series(
        search: search,
        limit: @per_page,
        offset: (page - 1) * @per_page
      )

    has_more = length(series) >= @per_page
    empty_results = page == 1 && Enum.empty?(series)

    socket
    |> stream(:series, series)
    |> assign(has_more: has_more)
    |> assign(loading: false)
    |> assign(empty_results: empty_results)
  end

  defp load_series(%{assigns: %{source: "iptv", provider: nil, sort: sort}} = socket)
       when sort in ["popularity", "rating"] do
    page = socket.assigns.page
    total_limit = page * @per_page
    drop = (page - 1) * @per_page

    series =
      case sort do
        "popularity" -> Iptv.list_trending("series", limit: total_limit)
        "rating" -> Iptv.list_top_10_series(limit: total_limit)
      end
      |> Enum.drop(drop)

    has_more = sort != "rating" and length(series) >= @per_page
    empty_results = page == 1 and Enum.empty?(series)

    socket
    |> stream(:series, series)
    |> assign(has_more: has_more)
    |> assign(loading: false)
    |> assign(empty_results: empty_results)
  end

  defp load_series(%{assigns: %{provider: nil}} = socket) do
    socket
    |> assign(has_more: false)
    |> assign(loading: false)
    |> assign(empty_results: true)
  end

  defp load_series(socket) do
    user = socket.assigns.user
    provider_id = socket.assigns.provider.id
    category = socket.assigns.selected_category
    search = socket.assigns.search
    page = socket.assigns.page

    series =
      Iptv.list_series(provider_id,
        category_id: category,
        search: search,
        limit: @per_page,
        offset: (page - 1) * @per_page,
        show_adult: user.show_adult_content
      )

    has_more = length(series) >= @per_page
    empty_results = page == 1 && Enum.empty?(series)

    socket
    |> stream(:series, series)
    |> assign(has_more: has_more)
    |> assign(loading: false)
    |> assign(empty_results: empty_results)
  end

  defp load_favorites_map(socket) do
    user_id = socket.assigns.user_id
    # Optimized: only fetches content_ids instead of full records
    favorite_ids = Iptv.list_favorite_ids(user_id, "series")
    assign(socket, favorites_map: favorite_ids)
  end

  defp filter_adult_categories(categories, true), do: categories
  defp filter_adult_categories(categories, _), do: Enum.reject(categories, & &1.is_adult)

  # Path builders based on mode and source
  defp build_path(%{assigns: %{mode: :browse, source: source}}, nil, "") do
    case source do
      "gindex" -> ~p"/browse/series?source=gindex"
      _ -> ~p"/browse/series"
    end
  end

  defp build_path(%{assigns: %{mode: :browse, source: source}}, nil, search) do
    case source do
      "gindex" -> ~p"/browse/series?source=gindex&search=#{search}"
      _ -> ~p"/browse/series?search=#{search}"
    end
  end

  defp build_path(%{assigns: %{mode: :browse, source: source}}, category, "") do
    case source do
      "gindex" -> ~p"/browse/series?source=gindex&category=#{category}"
      _ -> ~p"/browse/series?category=#{category}"
    end
  end

  defp build_path(%{assigns: %{mode: :browse, source: source}}, category, search) do
    case source do
      "gindex" -> ~p"/browse/series?source=gindex&category=#{category}&search=#{search}"
      _ -> ~p"/browse/series?category=#{category}&search=#{search}"
    end
  end

  defp build_path(%{assigns: %{mode: :provider, provider: provider}}, nil, ""),
    do: ~p"/providers/#{provider.id}/series"

  defp build_path(%{assigns: %{mode: :provider, provider: provider}}, nil, search),
    do: ~p"/providers/#{provider.id}/series?search=#{search}"

  defp build_path(%{assigns: %{mode: :provider, provider: provider}}, category, ""),
    do: ~p"/providers/#{provider.id}/series?category=#{category}"

  defp build_path(%{assigns: %{mode: :provider, provider: provider}}, category, search),
    do: ~p"/providers/#{provider.id}/series?category=#{category}&search=#{search}"

  # Detail path based on source
  defp detail_path(%{assigns: %{source: "gindex"}}, id), do: ~p"/gindex/series/#{id}"
  defp detail_path(%{assigns: %{mode: :browse}}, id), do: ~p"/browse/series/#{id}"

  defp detail_path(%{assigns: %{mode: :provider, provider: provider}}, id),
    do: ~p"/providers/#{provider.id}/series/#{id}"
end
