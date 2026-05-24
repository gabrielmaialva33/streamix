defmodule StreamixWeb.HomeLive do
  use StreamixWeb, :live_view

  alias StreamixWeb.Home.Data

  import StreamixWeb.HomeComponents

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Início")
      |> assign(current_path: "/")
      |> Data.assign_empty()

    if connected?(socket) do
      # WS attached: skeleton + async load for snappy LV update.
      send(self(), :load_data)
      {:ok, assign(socket, loading: true)}
    else
      # HTTP first render: load synchronously. Safari iOS sometimes never
      # settles the WS handshake on "/", which used to leave the skeleton
      # stuck forever. Paying a bit of TTFB here keeps the page usable
      # even if the upgrade fails; each section has its own timeout +
      # fallback inside HomeCatalogLoader.
      {:ok, socket |> assign(loading: false) |> Data.load()}
    end
  end

  def handle_info(:load_data, socket) do
    {:noreply, Data.load(socket)}
  end

  # ============================================
  # Event Handlers
  # ============================================

  # ThemeToggle hook event (client-side theme management, no server action needed)
  def handle_event("theme_init", _params, socket), do: {:noreply, socket}

  # Shared card navigation events (movie_card / series_card from
  # StreamixWeb.Content.CardComponents). The home carousels delegate rendering
  # to the shared cards, which emit these LV events instead of rendering a
  # `<.link navigate>`. We translate them into push_navigate calls so the UX
  # stays identical to the old inline cards that wrapped everything in a link.
  def handle_event("play_movie", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/browse/movies/#{id}")}
  end

  def handle_event("show_details", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/browse/movies/#{id}")}
  end

  def handle_event("view_series", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/browse/series/#{id}")}
  end

  def handle_event("toggle_featured_favorite", _, socket) do
    {:noreply, Data.toggle_featured_favorite(socket)}
  end

  def handle_event("toggle_favorite", %{"id" => id, "type" => type}, socket) do
    {:noreply, Data.toggle_content_favorite(socket, type, id)}
  end

  # AI Section Filter Events
  def handle_event("filter_trending_genre", %{"genre" => genre}, socket) do
    {:noreply, Data.filter_trending_genre(socket, genre)}
  end

  def handle_event("filter_trending_period", %{"period" => period}, socket) do
    {:noreply, Data.filter_trending_period(socket, period)}
  end

  def handle_event("filter_series_genre", %{"genre" => genre}, socket) do
    {:noreply, Data.filter_series_genre(socket, genre)}
  end

  def handle_event("filter_channels_category", %{"genre" => category}, socket) do
    {:noreply, Data.filter_channels_category(socket, category)}
  end

  def render(assigns) do
    ~H"""
    <div>
      <%= if @loading do %>
        <.skeleton_page rows={4} />
      <% else %>
        <%= if @current_scope do %>
          <.render_authenticated_home {assigns} />
        <% else %>
          <.render_landing_page {assigns} />
        <% end %>
      <% end %>
    </div>
    """
  end

  # ============================================
  # Landing Page (Guest / Not logged in)
  # ============================================
end
