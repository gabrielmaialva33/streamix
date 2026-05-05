defmodule StreamixWeb.Home.Data do
  @moduledoc """
  Data loading and state transitions for `StreamixWeb.HomeLive`.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias Streamix.AI.UserAnalytics
  alias Streamix.Cache
  alias Streamix.Iptv
  alias StreamixWeb.HomeCatalogLoader

  @trending_ttl 3 * 3600
  @top_10_ttl 24 * 3600
  @genre_filters_ttl 3600

  def assign_empty(socket) do
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
    |> assign(movie_progress: %{})
    |> assign(series_progress: %{})
    |> assign(trending_genre: "all")
    |> assign(trending_period: 7)
    |> assign(series_genre: "all")
    |> assign(channels_category: "all")
    |> assign(genre_filters: UserAnalytics.get_user_genre_filters(nil))
    |> assign(period_filters: UserAnalytics.get_period_filters())
    |> assign(channel_filters: UserAnalytics.get_channel_category_filters())
  end

  def load(socket) do
    socket
    |> load_public_catalog()
    |> load_user_data()
    |> assign(loading: false)
  end

  def filter_trending_genre(socket, genre) do
    trending = load_trending(user_id(socket), genre, socket.assigns.trending_period)

    socket
    |> assign(trending_genre: genre)
    |> assign(trending: trending)
  end

  def filter_trending_period(socket, period) do
    period_days = parse_period_days(period)
    trending = load_trending(user_id(socket), socket.assigns.trending_genre, period_days)

    socket
    |> assign(trending_period: period_days)
    |> assign(trending: trending)
  end

  def filter_series_genre(socket, genre) do
    socket
    |> assign(series_genre: genre)
    |> assign(series: load_series(user_id(socket), genre))
  end

  def filter_channels_category(socket, category) do
    socket
    |> assign(channels_category: category)
    |> assign(channels: load_channels(user_id(socket), category))
  end

  def toggle_featured_favorite(%{assigns: %{current_scope: nil}} = socket), do: socket
  def toggle_featured_favorite(%{assigns: %{featured: nil}} = socket), do: socket

  def toggle_featured_favorite(socket) do
    %{current_scope: scope, featured: {type, content}, featured_favorite: is_favorite} =
      socket.assigns

    content_type = content_type(type)

    if is_favorite do
      Iptv.remove_favorite(scope.user.id, content_type, content.id)
    else
      Iptv.add_favorite(scope.user.id, %{
        content_type: content_type,
        content_id: content.id,
        content_name: content.title || content.name,
        content_icon: content.stream_icon || content.cover
      })
    end

    assign(socket, featured_favorite: !is_favorite)
  end

  def user_id(socket) do
    case socket.assigns.current_scope do
      nil -> nil
      scope -> scope.user.id
    end
  end

  defp load_public_catalog(socket) do
    sections =
      HomeCatalogLoader.load(%{
        featured: fn -> Iptv.get_featured_content() end,
        stats: fn -> Iptv.get_public_stats() end,
        trending: fn ->
          load_trending(
            user_id(socket),
            socket.assigns.trending_genre,
            socket.assigns.trending_period
          )
        end,
        new_releases: fn -> Iptv.list_new_releases(limit: 12) end,
        top_10: fn -> load_top_10() end,
        movies: fn -> Iptv.list_public_movies(limit: 12) end,
        series: fn -> load_series(user_id(socket), socket.assigns.series_genre) end,
        channels: fn -> load_channels(user_id(socket), socket.assigns.channels_category) end
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

  defp load_user_data(%{assigns: %{current_scope: nil}} = socket) do
    socket
    |> assign(favorites: [])
    |> assign(history: [])
    |> assign(recommendations: [])
    |> assign(featured_favorite: false)
  end

  defp load_user_data(socket) do
    user_id = socket.assigns.current_scope.user.id
    movie_ids = collect_content_ids(socket.assigns, [:movies, :trending, :new_releases, :top_10])
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

  defp load_top_10 do
    Cache.fetch("home:top_10", @top_10_ttl, fn ->
      Iptv.list_top_10_movies(limit: 10)
    end)
  end

  defp load_series(nil, _genre), do: Iptv.list_public_series(limit: 12)

  defp load_series(user_id, genre) do
    UserAnalytics.get_personalized_series(user_id, limit: 12, genre: genre)
  end

  defp load_channels(nil, _category), do: Iptv.list_public_channels(limit: 24)

  defp load_channels(user_id, category) do
    UserAnalytics.get_personalized_channels(user_id, limit: 24, category: category)
  end

  defp load_recommendations(user_id) do
    case UserAnalytics.get_recommendations(user_id, limit: 12) do
      recommendations when is_list(recommendations) -> recommendations
      {:ok, recommendations} -> recommendations
      _ -> []
    end
  end

  defp load_genre_filters(user_id) do
    Cache.fetch("home:genre_filters:user:#{user_id}", @genre_filters_ttl, fn ->
      UserAnalytics.get_user_genre_filters(user_id)
    end)
  end

  defp collect_content_ids(assigns, keys) do
    keys
    |> Enum.flat_map(fn key -> Map.get(assigns, key, []) end)
    |> Enum.map(& &1.id)
    |> Enum.uniq()
  end

  defp check_featured_favorite(nil, _user_id), do: false

  defp check_featured_favorite({type, content}, user_id) do
    Iptv.is_favorite?(user_id, content_type(type), content.id)
  end

  defp content_type(:movie), do: "movie"
  defp content_type(_), do: "series"

  defp parse_period_days("all"), do: nil

  defp parse_period_days(period) when is_binary(period) do
    case Integer.parse(period) do
      {days, ""} when days > 0 -> days
      _ -> nil
    end
  end

  defp parse_period_days(_), do: nil
end
