defmodule StreamixWeb.Content.MoviesLive do
  @moduledoc """
  LiveView for browsing movies from a provider.
  Works for both /browse/movies (global provider) and /providers/:id/movies (user provider).
  Supports source=gindex param for GIndex content.
  """
  use StreamixWeb, :live_view

  import StreamixWeb.App.Feedback
  import StreamixWeb.App.Filters
  import StreamixWeb.App.Premium
  import StreamixWeb.Content.CardComponents
  import StreamixWeb.Content.NavigationComponents

  alias StreamixWeb.Content.Browse

  # Mount for /browse/movies (global provider or gindex)
  def mount(%{}, _session, socket) when not is_map_key(socket.assigns, :provider) do
    {:ok, Browse.init_socket(socket, :movies)}
  end

  def handle_params(params, _url, socket) do
    case Browse.assign_params(socket, :movies, params) do
      {:ok, socket} ->
        {:noreply, socket}

      {:redirect, socket} ->
        {:noreply, socket}
    end
  end

  # ============================================
  # Event Handlers
  # ============================================

  def handle_event("filter_category", %{"category" => category}, socket) do
    category = if category == "", do: nil, else: category

    {:noreply,
     push_patch(socket, to: Browse.build_path(socket, :movies, category, socket.assigns.search))}
  end

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply,
     push_patch(socket,
       to: Browse.build_path(socket, :movies, socket.assigns.selected_category, search)
     )}
  end

  def handle_event("filter_provider", %{"provider" => provider}, socket) do
    {:noreply, push_patch(socket, to: Browse.provider_filter_path(socket, :movies, provider))}
  end

  def handle_event("load_more", _, socket) do
    socket = Browse.load_more(socket, :movies)
    {:reply, %{page: socket.assigns.page}, socket}
  end

  def handle_event("play_movie", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: Browse.detail_path(socket, :movies, id))}
  end

  def handle_event("show_details", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: Browse.detail_path(socket, :movies, id))}
  end

  def handle_event("toggle_favorite", %{"id" => id, "type" => "movie"}, socket) do
    {:noreply, Browse.toggle_favorite(socket, :movies, id)}
  end

  # ============================================
  # Render
  # ============================================

  def render(assigns) do
    ~H"""
    <div id="movies-browse" phx-hook="BrowseScrollRestoration" class="space-y-4 sm:space-y-5">
      <div class="browse-toolbar">
        <%!-- Row 1: Source toggle + Content tabs --%>
        <div class="browse-toolbar__row">
          <%= if @mode == :browse do %>
            <.source_tabs selected={@source} path="/browse/movies" />
            <div class="browse-toolbar__divider" />
            <.browse_tabs
              selected={:movies}
              source={@source}
              query_params={Browse.browse_tab_params(assigns)}
              counts={Browse.counts(assigns, :movies)}
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

          <.provider_dropdown
            :if={@mode == :browse and @source == "iptv"}
            providers={@provider_options}
            selected={@provider_filter}
          />

          <.search_input
            id="movies-search-form"
            value={@search}
            placeholder="Buscar filmes..."
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
            id="movies"
            phx-update="stream"
            class="responsive-poster-grid"
          >
            <div :for={{dom_id, movie} <- @streams.movies} id={dom_id}>
              <.movie_card
                movie={movie}
                is_favorite={MapSet.member?(@favorites_map, movie.id)}
                source={@source}
                show_premium_badge={@mode == :browse and @source == "iptv" and not @premium_access}
              />
            </div>
          </div>

          <!-- Infinite Scroll Sentinel -->
          <div
            :if={@has_more && !@loading}
            id="movies-sentinel"
            phx-hook="InfiniteScroll"
            data-page={@page}
            data-sync-page-url="true"
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
            icon="hero-film"
            title="Nenhum filme encontrado"
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
end
