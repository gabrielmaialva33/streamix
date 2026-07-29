defmodule StreamixWeb.HomeLive do
  use StreamixWeb, :live_view

  require Logger

  alias StreamixWeb.HomeData, as: Data

  import StreamixWeb.HomeComponents

  def mount(_params, _session, socket) do
    Logger.info(
      "[HomeLive] mount connected=#{connected?(socket)} user_id=#{user_id_from_socket(socket)}"
    )

    socket =
      socket
      |> assign(page_title: "Início")
      |> assign(current_path: "/")
      |> assign(loading: true)
      |> Data.assign_empty()

    # Load data asynchronously for skeleton screen effect
    if connected?(socket) do
      send(self(), :load_data)
    end

    {:ok, socket}
  end

  def handle_info(:load_data, socket) do
    Logger.info("[HomeLive] :load_data fired user_id=#{user_id_from_socket(socket)}")
    {:noreply, Data.load(socket)}
  end

  defp user_id_from_socket(%{assigns: %{current_scope: %{user: %{id: id}}}}), do: id
  defp user_id_from_socket(_), do: nil

  # ============================================
  # Event Handlers
  # ============================================

  # ThemeToggle hook event (client-side theme management, no server action needed)
  def handle_event("theme_init", _params, socket), do: {:noreply, socket}

  # Shared card navigation events (movie_card / series_card from
  # StreamixWeb.Content.CardComponents). The home carousels delegate rendering
  # to the shared cards, which emit these LV events instead of rendering a
  # `<.link navigate>`. These destinations belong to the authenticated
  # live_session, so use an HTTP redirect instead of crossing sessions over
  # the existing LiveView socket.
  def handle_event("play_movie", %{"id" => id}, socket) do
    {:noreply, redirect(socket, to: with_return_to(~p"/browse/movies/#{id}", ~p"/"))}
  end

  def handle_event("show_details", %{"id" => id}, socket) do
    {:noreply, redirect(socket, to: with_return_to(~p"/browse/movies/#{id}", ~p"/"))}
  end

  def handle_event("view_series", %{"id" => id}, socket) do
    {:noreply, redirect(socket, to: with_return_to(~p"/browse/series/#{id}", ~p"/"))}
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

  defp with_return_to(path, return_to) do
    path <> "?return_to=" <> URI.encode_www_form(return_to)
  end

  def render(assigns) do
    ~H"""
    <div data-loading-home={@loading && "true"}>
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
