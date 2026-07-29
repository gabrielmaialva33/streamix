defmodule StreamixWeb.HomeLive do
  use StreamixWeb, :live_view

  require Logger

  alias StreamixWeb.HomeData, as: Data
  alias StreamixWeb.LiveSessionNavigation

  import StreamixWeb.Home.Authenticated
  import StreamixWeb.Home.Landing

  def mount(_params, _session, socket) do
    Logger.info(
      "[HomeLive] mount connected=#{connected?(socket)} user_id=#{user_id_from_socket(socket)}"
    )

    socket =
      socket
      |> assign(page_title: "Início")
      |> assign(current_path: home_path(socket))
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

  # `/` is the public session while `/home` is authenticated. The classifier
  # keeps signed-in card navigation on the current LiveView socket and falls
  # back to a normal redirect for the public landing.
  def handle_event("play_movie", %{"id" => id}, socket) do
    {:noreply, navigate_from_home(socket, ~p"/browse/movies/#{id}")}
  end

  def handle_event("show_details", %{"id" => id}, socket) do
    {:noreply, navigate_from_home(socket, ~p"/browse/movies/#{id}")}
  end

  def handle_event("view_series", %{"id" => id}, socket) do
    {:noreply, navigate_from_home(socket, ~p"/browse/series/#{id}")}
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

  defp navigate_from_home(socket, path) do
    current_path = socket.assigns.current_path
    LiveSessionNavigation.navigate(socket, current_path, with_return_to(path, current_path))
  end

  defp home_path(%{host_uri: %URI{path: "/home"}}), do: "/home"
  defp home_path(_socket), do: "/"

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
