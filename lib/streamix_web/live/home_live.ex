defmodule StreamixWeb.HomeLive do
  use StreamixWeb, :live_view

  alias Streamix.AI.UserAnalytics
  alias Streamix.Cache
  alias Streamix.Iptv
  alias StreamixWeb.Helpers.ImageProxy
  alias StreamixWeb.HomeCatalogLoader
  import StreamixWeb.HomeComponents

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Início")
      |> assign(current_path: "/")
      |> assign(loading: true)
      |> assign_empty_data()

    # Load data asynchronously for skeleton screen effect
    if connected?(socket) do
      send(self(), :load_data)
    end

    {:ok, socket}
  end

  # Initialize with empty data for skeleton display
  defp assign_empty_data(socket) do
    socket
    |> assign(featured: nil)
    |> assign(stats: %{movies_count: 0, series_count: 0, channels_count: 0})
    |> assign(movies: [])
    |> assign(series: [])
    |> assign(channels: [])
    |> assign(favorites: [])
    |> assign(history: [])
    |> assign(recommendations: [])
    |> assign(trending: [])
    |> assign(new_releases: [])
    |> assign(top_10: [])
    |> assign(featured_favorite: false)
    # Watch progress maps (content_id => 0.0..1.0)
    |> assign(movie_progress: %{})
    |> assign(series_progress: %{})
    # AI-powered section filters
    |> assign(trending_genre: "all")
    |> assign(trending_period: 7)
    |> assign(series_genre: "all")
    |> assign(channels_category: "all")
    # Filter options (loaded with user data)
    |> assign(genre_filters: UserAnalytics.get_user_genre_filters(nil))
    |> assign(period_filters: UserAnalytics.get_period_filters())
    |> assign(channel_filters: UserAnalytics.get_channel_category_filters())
  end

  def handle_info(:load_data, socket) do
    socket =
      socket
      |> load_public_catalog()
      |> load_user_data()
      |> assign(loading: false)

    {:noreply, socket}
  end

  defp load_public_catalog(socket) do
    user_id = get_user_id(socket)
    trending_genre = socket.assigns.trending_genre
    trending_period = socket.assigns.trending_period
    series_genre = socket.assigns.series_genre
    channels_category = socket.assigns.channels_category

    sections =
      HomeCatalogLoader.load(%{
        featured: fn -> Iptv.get_featured_content() end,
        stats: fn -> Iptv.get_public_stats() end,
        trending: fn -> load_trending(user_id, trending_genre, trending_period) end,
        new_releases: fn -> Iptv.list_new_releases(limit: 12) end,
        top_10: fn -> load_top_10() end,
        movies: fn -> Iptv.list_public_movies(limit: 12) end,
        series: fn -> load_series(user_id, series_genre) end,
        channels: fn -> load_channels(user_id, channels_category) end
      })

    socket
    |> assign(:featured, sections.featured)
    |> assign(:stats, sections.stats)
    |> assign(:trending, sections.trending)
    |> assign(:new_releases, sections.new_releases)
    |> assign(:top_10, sections.top_10)
    |> assign(:movies, sections.movies)
    |> assign(:series, sections.series)
    |> assign(:channels, sections.channels)
  end

  # Load trending with AI personalization when user is logged in
  # Cached for 3 hours to avoid repeated heavy queries
  @trending_ttl 3 * 3600

  defp load_trending(nil, _genre, period) do
    Cache.fetch("home:trending:guest:#{period}", @trending_ttl, fn ->
      Iptv.list_trending_movies(limit: 12, days: period)
    end)
  end

  defp load_trending(user_id, genre, period) do
    Cache.fetch("home:trending:user:#{user_id}:#{genre}:#{period}", @trending_ttl, fn ->
      UserAnalytics.get_personalized_trending(user_id,
        limit: 12,
        genre: genre,
        days: period
      )
    end)
  end

  # Load top 10 movies, cached for 24 hours (changes rarely)
  @top_10_ttl 24 * 3600

  defp load_top_10 do
    Cache.fetch("home:top_10", @top_10_ttl, fn ->
      Iptv.list_top_10_movies(limit: 10)
    end)
  end

  # Load series with AI personalization
  defp load_series(nil, _genre) do
    Iptv.list_public_series(limit: 12)
  end

  defp load_series(user_id, genre) do
    UserAnalytics.get_personalized_series(user_id,
      limit: 12,
      genre: genre
    )
  end

  # Load channels with AI personalization
  defp load_channels(nil, _category) do
    Iptv.list_public_channels(limit: 24)
  end

  defp load_channels(user_id, category) do
    UserAnalytics.get_personalized_channels(user_id,
      limit: 24,
      category: category
    )
  end

  defp get_user_id(socket) do
    case socket.assigns.current_scope do
      nil -> nil
      scope -> scope.user.id
    end
  end

  defp load_user_data(socket) do
    case socket.assigns.current_scope do
      nil ->
        socket
        |> assign(favorites: [])
        |> assign(history: [])
        |> assign(recommendations: [])
        |> assign(featured_favorite: false)

      scope ->
        user_id = scope.user.id

        movie_ids =
          collect_content_ids(socket.assigns, [:movies, :trending, :new_releases, :top_10])

        series_ids = collect_content_ids(socket.assigns, [:series])

        user_sections =
          HomeCatalogLoader.load(%{
            favorites: fn -> Iptv.list_home_favorites(user_id, limit: 12) end,
            history: fn -> Iptv.list_home_history(user_id, limit: 6) end,
            recommendations: fn -> load_recommendations(user_id) end,
            featured_favorite: fn -> check_featured_favorite(socket.assigns.featured, user_id) end,
            movie_progress: fn -> Iptv.get_watch_progress_map(user_id, "movie", movie_ids) end,
            series_progress: fn -> Iptv.get_series_progress_map(user_id, series_ids) end,
            genre_filters: fn -> load_genre_filters(user_id) end
          })

        socket
        |> assign(:favorites, user_sections.favorites)
        |> assign(:history, user_sections.history)
        |> assign(:recommendations, user_sections.recommendations)
        |> assign(:featured_favorite, user_sections.featured_favorite)
        |> assign(:movie_progress, user_sections.movie_progress)
        |> assign(:series_progress, user_sections.series_progress)
        |> assign(:genre_filters, user_sections.genre_filters)
    end
  end

  defp collect_content_ids(assigns, keys) do
    keys
    |> Enum.flat_map(fn key -> Map.get(assigns, key, []) end)
    |> Enum.map(& &1.id)
    |> Enum.uniq()
  end

  # Load AI-powered personalized recommendations
  defp load_recommendations(user_id) do
    case UserAnalytics.get_recommendations(user_id, limit: 12) do
      recommendations when is_list(recommendations) -> recommendations
      {:ok, recommendations} -> recommendations
      _ -> []
    end
  end

  # Load user genre filters with cache (1 hour TTL)
  @genre_filters_ttl 3600

  defp load_genre_filters(user_id) do
    Cache.fetch("home:genre_filters:user:#{user_id}", @genre_filters_ttl, fn ->
      UserAnalytics.get_user_genre_filters(user_id)
    end)
  end

  defp check_featured_favorite(nil, _user_id), do: false

  defp check_featured_favorite({type, content}, user_id) do
    content_type = if type == :movie, do: "movie", else: "series"
    Iptv.is_favorite?(user_id, content_type, content.id)
  end

  # ============================================
  # Event Handlers
  # ============================================

  # ThemeToggle hook event (client-side theme management, no server action needed)
  def handle_event("theme_init", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_featured_favorite", _, socket) do
    case {socket.assigns.current_scope, socket.assigns.featured} do
      {nil, _} ->
        {:noreply, socket}

      {_, nil} ->
        {:noreply, socket}

      {scope, {type, content}} ->
        user_id = scope.user.id
        content_type = if type == :movie, do: "movie", else: "series"
        is_favorite = socket.assigns.featured_favorite

        if is_favorite do
          Iptv.remove_favorite(user_id, content_type, content.id)
        else
          Iptv.add_favorite(user_id, %{
            content_type: content_type,
            content_id: content.id,
            content_name: content.title || content.name,
            content_icon: content.stream_icon || content.cover
          })
        end

        {:noreply, assign(socket, featured_favorite: !is_favorite)}
    end
  end

  # AI Section Filter Events
  def handle_event("filter_trending_genre", %{"genre" => genre}, socket) do
    user_id = get_user_id(socket)
    trending = load_trending(user_id, genre, socket.assigns.trending_period)

    {:noreply,
     socket
     |> assign(trending_genre: genre)
     |> assign(trending: trending)}
  end

  def handle_event("filter_trending_period", %{"period" => period}, socket) do
    user_id = get_user_id(socket)
    # Parse period - "all" means nil, otherwise parse as integer
    period_days = if period == "all", do: nil, else: String.to_integer(period)
    trending = load_trending(user_id, socket.assigns.trending_genre, period_days)

    {:noreply,
     socket
     |> assign(trending_period: period_days)
     |> assign(trending: trending)}
  end

  def handle_event("filter_series_genre", %{"genre" => genre}, socket) do
    user_id = get_user_id(socket)
    series = load_series(user_id, genre)

    {:noreply,
     socket
     |> assign(series_genre: genre)
     |> assign(series: series)}
  end

  def handle_event("filter_channels_category", %{"genre" => category}, socket) do
    user_id = get_user_id(socket)
    channels = load_channels(user_id, category)

    {:noreply,
     socket
     |> assign(channels_category: category)
     |> assign(channels: channels)}
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
