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
      |> assign(loading: false)
      |> Data.assign_empty()
      |> maybe_start_home_tasks()

    {:ok, socket}
  end

  def handle_async(task, {:ok, sections}, socket)
      when task in [:home_catalog, :home_personalization, :home_library, :home_annotations] do
    group = task_group(task)

    socket =
      socket
      |> Data.apply_sections(sections)
      |> Data.mark_loaded(group)
      |> maybe_start_annotations()

    emit_home_group(group, :ok)
    {:noreply, socket}
  end

  def handle_async(task, {:exit, reason}, socket)
      when task in [:home_catalog, :home_personalization, :home_library, :home_annotations] do
    group = task_group(task)
    Logger.warning("[HomeLive] #{group} load failed: #{inspect(reason)}")
    emit_home_group(group, :error)

    {:noreply,
     socket
     |> Data.mark_loaded(group)
     |> maybe_start_annotations()}
  end

  defp user_id_from_socket(%{assigns: %{current_scope: %{user: %{id: id}}}}), do: id
  defp user_id_from_socket(_), do: nil

  defp maybe_start_home_tasks(socket) do
    if connected?(socket) do
      snapshot = home_snapshot(socket.assigns)

      socket
      |> start_async(:home_catalog, fn -> Data.catalog_sections(snapshot) end)
      |> start_async(:home_personalization, fn -> Data.personalization_sections(snapshot) end)
      |> start_async(:home_library, fn -> Data.library_sections(snapshot) end)
    else
      socket
    end
  end

  defp maybe_start_annotations(socket) do
    if connected?(socket) and Data.ready_for_annotations?(socket.assigns) and
         Data.loading?(socket.assigns, :annotations) do
      snapshot = home_snapshot(socket.assigns)

      socket
      |> Data.mark_started(:annotations)
      |> start_async(:home_annotations, fn -> Data.annotation_sections(snapshot) end)
    else
      socket
    end
  end

  defp home_snapshot(assigns) do
    Map.take(assigns, [
      :current_scope,
      :featured,
      :movies,
      :series,
      :channels,
      :trending,
      :new_releases,
      :top_10,
      :trending_genre,
      :trending_period,
      :series_genre,
      :channels_category
    ])
  end

  defp task_group(:home_catalog), do: :catalog
  defp task_group(:home_personalization), do: :personalization
  defp task_group(:home_library), do: :library
  defp task_group(:home_annotations), do: :annotations

  defp emit_home_group(group, status) do
    :telemetry.execute(
      [:streamix, :home, :group],
      %{count: 1},
      %{group: group, status: status}
    )
  end

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
    <div
      id="home-progressive-shell"
      data-loading-home={@loading && "true"}
      aria-busy={Enum.any?(@home_loading, fn {_group, loading?} -> loading? end)}
    >
      <%= if @current_scope do %>
        <.render_authenticated_home {assigns} />
      <% else %>
        <.render_landing_page {assigns} />
      <% end %>
    </div>
    """
  end

  # ============================================
  # Landing Page (Guest / Not logged in)
  # ============================================
end
