defmodule StreamixWeb.HomeData do
  @moduledoc """
  Data loading and state transitions for `StreamixWeb.HomeLive`.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias Streamix.AI.UserAnalytics
  alias Streamix.Cache
  alias Streamix.Iptv
  alias StreamixWeb.Content.FavoriteState
  alias StreamixWeb.HomeCatalogLoader

  @trending_ttl 3 * 3600
  @top_10_ttl 24 * 3600
  @genre_filters_ttl 3600

  # Per-section row counts. Centralised so every entrypoint into the home
  # page (mount, refresh, filter-change) lands on the same shape — used to
  # drift quietly across `load_public_catalog` / `load_user_data` /
  # `filter_trending_genre`, leading to the trending shelf showing 12
  # cards and the genre-filtered version showing 6.
  @home_default_limit 12
  @home_history_limit 6
  @home_channels_limit 24
  @home_top_10_limit 10

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
    |> assign(movie_favorites_map: MapSet.new())
    |> assign(series_favorites_map: MapSet.new())
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
    |> prefetch_personalization()
    |> load_public_catalog()
    |> load_user_data()
    |> assign(loading: false)
  end

  # Warm the ConCache entries the personalization sections all read so
  # the parallel fetchers hit a cache hit instead of racing for the same
  # lock. Without this, `:trending` + `:series` + `:recommendations` all
  # call `UserAnalytics.get_user_profile/1` (and `get_user_insights/1`)
  # at the same time; whoever loses the lock waits the full
  # `acquire_lock_timeout` and falls back to []. Concretely this was the
  # root cause of the home staying on its skeleton — reproduced in
  # `test/streamix_web/e2e/home_skeleton_test.exs`.
  defp prefetch_personalization(%{assigns: %{current_scope: nil}} = socket), do: socket

  defp prefetch_personalization(socket) do
    case user_id(socket) do
      nil ->
        socket

      uid ->
        # Result is discarded; the side effect is the populated cache.
        _ = UserAnalytics.get_user_profile(uid)
        _ = UserAnalytics.get_user_insights(uid)
        socket
    end
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

    result =
      FavoriteState.toggle(scope.user.id, content_type, content.id, %{
        content_name: content.title || content.name,
        content_icon: content.stream_icon || content.cover
      })

    assign(socket, featured_favorite: FavoriteState.preserve_boolean(is_favorite, result))
  end

  def toggle_content_favorite(%{assigns: %{current_scope: nil}} = socket, _type, _id), do: socket

  def toggle_content_favorite(socket, type, id) do
    with {:ok, content_type} <- normalize_favorite_type(type),
         {:ok, content_id} <- parse_content_id(id),
         {:ok, status} <-
           FavoriteState.toggle(socket.assigns.current_scope.user.id, content_type, content_id) do
      socket
      |> assign_favorite_map(content_type, content_id, status)
      |> refresh_home_favorites()
      |> refresh_featured_favorite()
    else
      _ -> socket
    end
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
        new_releases: fn -> Iptv.list_new_releases(limit: @home_default_limit) end,
        top_10: fn -> load_top_10() end,
        movies: fn -> Iptv.list_public_movies(limit: @home_default_limit) end,
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
    |> assign(movie_favorites_map: MapSet.new())
    |> assign(series_favorites_map: MapSet.new())
  end

  defp load_user_data(socket) do
    user_id = socket.assigns.current_scope.user.id
    movie_ids = collect_content_ids(socket.assigns, [:movies, :trending, :new_releases, :top_10])
    series_ids = collect_content_ids(socket.assigns, [:series])

    user_sections =
      HomeCatalogLoader.load(%{
        favorites: fn -> Iptv.list_home_favorites(user_id, limit: @home_default_limit) end,
        history: fn -> Iptv.list_home_history(user_id, limit: @home_history_limit) end,
        recommendations: fn -> load_recommendations(user_id) end,
        featured_favorite: fn -> check_featured_favorite(socket.assigns.featured, user_id) end,
        movie_favorites_map: fn -> Iptv.list_favorite_ids(user_id, "movie", movie_ids) end,
        series_favorites_map: fn -> Iptv.list_favorite_ids(user_id, "series", series_ids) end,
        movie_progress: fn -> Iptv.get_watch_progress_map(user_id, "movie", movie_ids) end,
        series_progress: fn -> Iptv.get_series_progress_map(user_id, series_ids) end,
        genre_filters: fn -> load_genre_filters(user_id) end
      })

    socket
    |> assign(:favorites, user_sections.favorites)
    |> assign(:history, user_sections.history)
    |> assign(:recommendations, user_sections.recommendations)
    |> assign(:featured_favorite, user_sections.featured_favorite)
    |> assign(:movie_favorites_map, user_sections.movie_favorites_map)
    |> assign(:series_favorites_map, user_sections.series_favorites_map)
    |> assign(:movie_progress, user_sections.movie_progress)
    |> assign(:series_progress, user_sections.series_progress)
    |> assign(:genre_filters, user_sections.genre_filters)
  end

  defp load_trending(nil, _genre, period) do
    Cache.fetch("home:trending:guest:#{period}", @trending_ttl, fn ->
      Iptv.list_trending_movies(limit: @home_default_limit, days: period)
    end)
  end

  defp load_trending(user_id, genre, period) do
    Cache.fetch("home:trending:user:#{user_id}:#{genre}:#{period}", @trending_ttl, fn ->
      UserAnalytics.get_personalized_trending(user_id,
        limit: @home_default_limit,
        genre: genre,
        days: period
      )
    end)
  end

  defp load_top_10 do
    Cache.fetch("home:top_10", @top_10_ttl, fn ->
      Iptv.list_top_10_movies(limit: @home_top_10_limit)
    end)
  end

  defp load_series(nil, _genre), do: Iptv.list_public_series(limit: @home_default_limit)

  defp load_series(user_id, genre) do
    UserAnalytics.get_personalized_series(user_id, limit: @home_default_limit, genre: genre)
  end

  defp load_channels(nil, _category), do: Iptv.list_public_channels(limit: @home_channels_limit)

  defp load_channels(user_id, category) do
    UserAnalytics.get_personalized_channels(user_id,
      limit: @home_channels_limit,
      category: category
    )
  end

  defp load_recommendations(user_id) do
    case UserAnalytics.get_recommendations(user_id, limit: @home_default_limit) do
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
    Iptv.favorite?(user_id, content_type(type), content.id)
  end

  defp content_type(:movie), do: "movie"
  defp content_type(_), do: "series"

  defp normalize_favorite_type(type) when type in ["movie", :movie], do: {:ok, "movie"}
  defp normalize_favorite_type(type) when type in ["series", :series], do: {:ok, "series"}
  defp normalize_favorite_type(_), do: :error

  defp parse_content_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp parse_content_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp parse_content_id(_), do: :error

  defp assign_favorite_map(socket, "movie", content_id, status) do
    assign(
      socket,
      :movie_favorites_map,
      update_favorite_map(socket.assigns.movie_favorites_map, content_id, status)
    )
  end

  defp assign_favorite_map(socket, "series", content_id, status) do
    assign(
      socket,
      :series_favorites_map,
      update_favorite_map(socket.assigns.series_favorites_map, content_id, status)
    )
  end

  defp update_favorite_map(map, content_id, :added), do: MapSet.put(map, content_id)
  defp update_favorite_map(map, content_id, :removed), do: MapSet.delete(map, content_id)

  defp refresh_home_favorites(socket) do
    assign(
      socket,
      :favorites,
      Iptv.list_home_favorites(socket.assigns.current_scope.user.id, limit: @home_default_limit)
    )
  end

  defp refresh_featured_favorite(socket) do
    assign(
      socket,
      :featured_favorite,
      check_featured_favorite(socket.assigns.featured, socket.assigns.current_scope.user.id)
    )
  end

  defp parse_period_days("all"), do: nil

  defp parse_period_days(period) when is_binary(period) do
    case Integer.parse(period) do
      {days, ""} when days > 0 -> days
      _ -> nil
    end
  end

  defp parse_period_days(_), do: nil
end
