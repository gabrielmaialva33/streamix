defmodule StreamixWeb.HomeData do
  @moduledoc """
  Data loading and state transitions for `StreamixWeb.HomeLive`.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias Streamix.AI
  alias Streamix.Cache
  alias Streamix.Library
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
  @home_groups [:catalog, :personalization, :library, :annotations]

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
    |> assign(genre_filters: AI.get_user_genre_filters(nil))
    |> assign(period_filters: AI.get_period_filters())
    |> assign(channel_filters: AI.get_channel_category_filters())
    |> assign(home_loading: Map.new(@home_groups, &{&1, true}))
  end

  @doc "Loads every home group synchronously for non-LiveView callers and tests."
  def load(socket) do
    socket
    |> apply_sections(catalog_sections(socket.assigns))
    |> apply_sections(personalization_sections(socket.assigns))
    |> apply_sections(library_sections(socket.assigns))
    |> then(fn loaded -> apply_sections(loaded, annotation_sections(loaded.assigns)) end)
    |> mark_all_loaded()
    |> assign(loading: false)
  end

  @doc "Applies a section result map to the LiveView socket."
  def apply_sections(socket, sections) when is_map(sections) do
    Enum.reduce(sections, socket, fn {key, value}, acc -> assign(acc, key, value) end)
  end

  @doc "Marks one progressive home group as running."
  def mark_started(socket, group) when group in @home_groups do
    assign(socket, :home_loading, Map.put(socket.assigns.home_loading, group, :running))
  end

  @doc "Marks one progressive home group as complete."
  def mark_loaded(socket, group) when group in @home_groups do
    assign(socket, :home_loading, Map.put(socket.assigns.home_loading, group, false))
  end

  @doc "Returns whether one progressive home group is still loading."
  def loading?(assigns, group) when is_map(assigns) and group in @home_groups do
    get_in(assigns, [:home_loading, group]) == true
  end

  @doc "Returns whether the catalog and personalization inputs are ready for annotations."
  def ready_for_annotations?(assigns) when is_map(assigns) do
    not loading?(assigns, :catalog) and not loading?(assigns, :personalization)
  end

  def filter_trending_genre(socket, genre) do
    trending =
      load_trending(
        user_id(socket),
        genre,
        socket.assigns.trending_period,
        show_adult_content?(socket)
      )

    socket
    |> assign(trending_genre: genre)
    |> assign(trending: trending)
  end

  def filter_trending_period(socket, period) do
    period_days = parse_period_days(period)

    trending =
      load_trending(
        user_id(socket),
        socket.assigns.trending_genre,
        period_days,
        show_adult_content?(socket)
      )

    socket
    |> assign(trending_period: period_days)
    |> assign(trending: trending)
  end

  def filter_series_genre(socket, genre) do
    socket
    |> assign(series_genre: genre)
    |> assign(series: load_series(user_id(socket), genre, show_adult_content?(socket)))
  end

  def filter_channels_category(socket, category) do
    socket
    |> assign(channels_category: category)
    |> assign(channels: load_channels(user_id(socket), category, show_adult_content?(socket)))
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

  def user_id(%{assigns: assigns}), do: user_id(assigns)
  def user_id(%{current_scope: nil}), do: nil
  def user_id(%{current_scope: %{user: %{id: id}}}), do: id
  def user_id(_assigns), do: nil

  @doc "Loads the non-personalized catalog shelves for progressive rendering."
  def catalog_sections(assigns) when is_map(assigns) do
    show_adult = show_adult_content?(assigns)

    sections =
      HomeCatalogLoader.load(
        %{
          featured: fn -> Streamix.Catalog.get_featured_content(show_adult: show_adult) end,
          stats: fn -> Streamix.Catalog.get_public_stats() end,
          new_releases: fn ->
            Streamix.Catalog.list_new_releases(limit: @home_default_limit, show_adult: show_adult)
          end,
          top_10: fn -> load_top_10(show_adult) end,
          movies: fn ->
            Streamix.Catalog.list_public_movies(
              limit: @home_default_limit,
              show_adult: show_adult
            )
          end
        },
        timeout: 8_000
      )

    Map.put(sections, :stats, public_stats(sections.stats, sections))
  end

  defp public_stats(stats, sections) do
    stats = normalize_public_stats(stats)

    if stale_public_stats?(stats, sections) do
      Streamix.Catalog.get_public_stats(refresh: true)
      |> normalize_public_stats()
    else
      stats
    end
  end

  defp normalize_public_stats(stats) do
    %{
      movies_count: public_count(stats, :movies_count),
      series_count: public_count(stats, :series_count),
      channels_count: public_count(stats, :channels_count)
    }
  end

  defp stale_public_stats?(stats, sections) do
    public_count(stats, :movies_count) < length(Map.get(sections, :movies, [])) or
      public_count(stats, :series_count) < length(Map.get(sections, :series, [])) or
      public_count(stats, :channels_count) < length(Map.get(sections, :channels, []))
  end

  defp public_count(stats, key) when is_map(stats) do
    Map.get(stats, key) || Map.get(stats, Atom.to_string(key), 0) || 0
  end

  defp public_count(_stats, _key), do: 0

  @doc "Loads shelves that use the shared user taste context."
  def personalization_sections(assigns) when is_map(assigns) do
    user_id = user_id(assigns)
    show_adult = show_adult_content?(assigns)
    personalization = personalization_context(user_id)

    HomeCatalogLoader.load(
      %{
        trending: fn ->
          load_trending(
            user_id,
            Map.get(assigns, :trending_genre, "all"),
            Map.get(assigns, :trending_period, 7),
            show_adult,
            personalization
          )
        end,
        series: fn ->
          load_series(
            user_id,
            Map.get(assigns, :series_genre, "all"),
            show_adult,
            personalization
          )
        end,
        channels: fn ->
          load_channels(user_id, Map.get(assigns, :channels_category, "all"), show_adult)
        end,
        recommendations: fn -> load_recommendations(user_id, show_adult, personalization) end,
        genre_filters: fn -> load_genre_filters(user_id) end
      },
      timeout: 8_000
    )
  end

  @doc "Loads the user's library shelves independently of AI and catalog queries."
  def library_sections(%{current_scope: nil}) do
    %{favorites: [], history: []}
  end

  def library_sections(%{current_scope: %{user: user}}) do
    HomeCatalogLoader.load(
      %{
        favorites: fn ->
          Library.list_home_favorites(user.id,
            limit: @home_default_limit,
            show_adult: user.show_adult_content
          )
        end,
        history: fn ->
          Library.list_home_history(user.id,
            limit: @home_history_limit,
            show_adult: user.show_adult_content
          )
        end
      },
      timeout: 6_000
    )
  end

  @doc "Loads favorite/progress annotations after the catalog shelves are available."
  def annotation_sections(%{current_scope: nil}) do
    %{
      featured_favorite: false,
      movie_favorites_map: MapSet.new(),
      series_favorites_map: MapSet.new(),
      movie_progress: %{},
      series_progress: %{}
    }
  end

  def annotation_sections(%{current_scope: %{user: user}} = assigns) do
    movie_ids = collect_content_ids(assigns, [:movies, :trending, :new_releases, :top_10])
    series_ids = collect_content_ids(assigns, [:series])

    HomeCatalogLoader.load(
      %{
        featured_favorite: fn -> check_featured_favorite(Map.get(assigns, :featured), user.id) end,
        movie_favorites_map: fn -> Library.list_favorite_ids(user.id, "movie", movie_ids) end,
        series_favorites_map: fn -> Library.list_favorite_ids(user.id, "series", series_ids) end,
        movie_progress: fn -> Library.get_watch_progress_map(user.id, "movie", movie_ids) end,
        series_progress: fn -> Library.get_series_progress_map(user.id, series_ids) end
      },
      timeout: 6_000
    )
  end

  defp load_trending(user_id, genre, period, show_adult, personalization \\ nil)

  defp load_trending(nil, _genre, period, _show_adult, _personalization) do
    Cache.fetch("home:trending:guest:#{period}", @trending_ttl, fn ->
      Streamix.Catalog.list_trending_movies(
        limit: @home_default_limit,
        days: period,
        show_adult: false
      )
    end)
  end

  defp load_trending(user_id, genre, period, show_adult, personalization) do
    cache_key = "home:trending:user:#{user_id}:#{genre}:#{period}:adult:#{show_adult}"
    personalization = personalization || personalization_context(user_id)

    Cache.fetch(cache_key, @trending_ttl, fn ->
      AI.get_personalized_trending(user_id,
        limit: @home_default_limit,
        genre: genre,
        days: period,
        show_adult: show_adult,
        profile: personalization.profile,
        insights: personalization.insights,
        semantic_scores: personalization.movie_scores
      )
    end)
  end

  defp load_top_10(show_adult) do
    Cache.fetch("home:top_10:adult:#{show_adult}", @top_10_ttl, fn ->
      Streamix.Catalog.list_top_10_movies(limit: @home_top_10_limit, show_adult: show_adult)
    end)
  end

  defp load_series(user_id, genre, show_adult, personalization \\ nil)

  defp load_series(nil, _genre, _show_adult, _personalization) do
    Streamix.Catalog.list_public_series(limit: @home_default_limit, show_adult: false)
  end

  defp load_series(user_id, genre, show_adult, personalization) do
    personalization = personalization || personalization_context(user_id)

    AI.get_personalized_series(user_id,
      limit: @home_default_limit,
      genre: genre,
      show_adult: show_adult,
      profile: personalization.profile,
      insights: personalization.insights,
      semantic_scores: personalization.series_scores
    )
  end

  defp load_channels(nil, _category, _show_adult) do
    Streamix.Catalog.list_public_channels(limit: @home_channels_limit, show_adult: false)
  end

  defp load_channels(user_id, category, show_adult) do
    AI.get_personalized_channels(user_id,
      limit: @home_channels_limit,
      category: category,
      show_adult: show_adult
    )
  end

  defp load_recommendations(nil, _show_adult, _personalization), do: []

  defp load_recommendations(user_id, show_adult, personalization) do
    ids = recommendation_ids(personalization.movie_recommendations)

    recommendations =
      user_id
      |> Streamix.Catalog.list_visible_movies_by_ids(ids, show_adult: show_adult)
      |> order_by_ids(ids)

    if length(recommendations) >= @home_default_limit do
      Enum.take(recommendations, @home_default_limit)
    else
      fallback =
        AI.get_personalized_trending(user_id,
          limit: @home_default_limit,
          show_adult: show_adult,
          profile: personalization.profile,
          insights: personalization.insights,
          semantic_scores: personalization.movie_scores
        )

      (recommendations ++ fallback)
      |> Enum.uniq_by(& &1.id)
      |> Enum.take(@home_default_limit)
    end
  end

  defp recommendation_ids(recommendations) do
    Enum.flat_map(recommendations, &recommendation_id/1)
  end

  defp recommendation_id(%{id: id}), do: normalize_recommendation_id(id)
  defp recommendation_id(%{"id" => id}), do: normalize_recommendation_id(id)
  defp recommendation_id(_recommendation), do: []

  defp normalize_recommendation_id(id) when is_integer(id) and id > 0, do: [id]

  defp normalize_recommendation_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} when parsed > 0 -> [parsed]
      _other -> []
    end
  end

  defp normalize_recommendation_id(_id), do: []

  defp load_genre_filters(nil), do: AI.get_user_genre_filters(nil)

  defp load_genre_filters(user_id) do
    Cache.fetch("home:genre_filters:user:#{user_id}", @genre_filters_ttl, fn ->
      AI.get_user_genre_filters(user_id)
    end)
  end

  defp personalization_context(nil) do
    %{
      profile: nil,
      insights: %{},
      movie_recommendations: [],
      series_recommendations: [],
      movie_scores: %{},
      series_scores: %{}
    }
  end

  defp personalization_context(user_id), do: AI.get_personalization_context(user_id)

  defp mark_all_loaded(socket) do
    assign(socket, :home_loading, Map.new(@home_groups, &{&1, false}))
  end

  defp order_by_ids(items, ids) do
    positions = ids |> Enum.with_index() |> Map.new()
    Enum.sort_by(items, &Map.get(positions, &1.id, length(ids)))
  end

  defp collect_content_ids(assigns, keys) do
    keys
    |> Enum.flat_map(fn key -> Map.get(assigns, key, []) end)
    |> Enum.map(& &1.id)
    |> Enum.uniq()
  end

  defp check_featured_favorite(nil, _user_id), do: false

  defp check_featured_favorite({type, content}, user_id) do
    Library.favorite?(user_id, content_type(type), content.id)
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
    user = socket.assigns.current_scope.user

    assign(
      socket,
      :favorites,
      Library.list_home_favorites(user.id,
        limit: @home_default_limit,
        show_adult: user.show_adult_content
      )
    )
  end

  defp show_adult_content?(%{assigns: assigns}), do: show_adult_content?(assigns)
  defp show_adult_content?(%{current_scope: %{user: user}}), do: user.show_adult_content
  defp show_adult_content?(_assigns), do: false

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
