defmodule StreamixWeb.Content.SeriesLive do
  @moduledoc """
  LiveView for browsing series from a provider.
  Works for both /browse/series (global provider) and /providers/:id/series (user provider).
  Supports source=gindex param for GIndex content.
  """
  use StreamixWeb, :live_view

  import StreamixWeb.App.Feedback
  import StreamixWeb.App.Filters
  import StreamixWeb.App.Premium
  import StreamixWeb.Content.CardComponents
  import StreamixWeb.Content.NavigationComponents

  alias StreamixWeb.Content.Browse

  # Mount for /browse/series (global provider or gindex)
  def mount(%{}, _session, socket) when not is_map_key(socket.assigns, :provider) do
    {:ok, Browse.init_socket(socket, :series)}
  end

  def handle_params(params, _url, socket) do
    case Browse.assign_params(socket, :series, params) do
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
     push_patch(socket, to: Browse.build_path(socket, :series, category, socket.assigns.search))}
  end

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply,
     push_patch(socket,
       to: Browse.build_path(socket, :series, socket.assigns.selected_category, search)
     )}
  end

  def handle_event("filter_provider", %{"provider" => provider}, socket) do
    {:noreply, push_patch(socket, to: Browse.provider_filter_path(socket, :series, provider))}
  end

  def handle_event("load_more", _, socket) do
    socket = Browse.load_more(socket, :series)
    {:reply, %{page: socket.assigns.page}, socket}
  end

  def handle_event("view_series", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: Browse.detail_path(socket, :series, id))}
  end

  def handle_event("toggle_favorite", %{"id" => id, "type" => "series"}, socket) do
    {:noreply, Browse.toggle_favorite(socket, :series, id)}
  end

  # ============================================
  # Render
  # ============================================

  def render(assigns) do
    ~H"""
    <div id="series-browse" phx-hook="BrowseScrollRestoration" class="space-y-4 sm:space-y-5">
      <div class="browse-toolbar">
        <%!-- Row 1: Source toggle + Content tabs --%>
        <div class="browse-toolbar__row">
          <%= if @mode == :browse do %>
            <.source_tabs selected={@source} path="/browse/series" />
            <div class="browse-toolbar__divider" />
            <.browse_tabs
              selected={:series}
              source={@source}
              query_params={Browse.browse_tab_params(assigns)}
              counts={Browse.counts(assigns, :series)}
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

          <.provider_dropdown
            :if={@mode == :browse and @source == "iptv"}
            providers={@provider_options}
            selected={@provider_filter}
          />

          <.search_input
            id="series-search-form"
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
end
