defmodule Streamix.AI.UserAnalytics do
  @moduledoc """
  AI-powered user analytics and personalized recommendations.

  Uses watch history + TMDB metadata + embeddings to create
  personalized content recommendations for each user.

  ## Features

  - **User Taste Profile**: Aggregated vector from watched content
  - **Personalized Recommendations**: "For You" based on watch history
  - **Similar Content**: "Because you watched X"
  - **Channel Affinity**: Recommended live channels
  - **Time-based Patterns**: "You like action on weekends"

  ## Architecture

  1. User watches content → WatchHistory saved
  2. Background job generates embedding for content
  3. User profile vector = weighted average of watched content vectors
  4. Recommendations = Qdrant search using profile vector
  """

  require Logger

  alias Streamix.AI.Embeddings
  alias Streamix.AI.Qdrant
  alias Streamix.Cache
  alias Streamix.Iptv.Catalog
  alias Streamix.Iptv.Genre
  alias Streamix.Iptv.History
  alias Streamix.Iptv.LiveChannel
  alias Streamix.Repo

  import Ecto.Query

  @user_profile_collection "user_profiles"
  @recommendations_ttl 3600

  # ============================================================================
  # User Profile
  # ============================================================================

  @doc """
  Computes and stores a user's taste profile based on watch history.

  The profile is a weighted average of content embeddings:
  - More recent = higher weight
  - Completed = higher weight
  - Longer watch time = higher weight

  Returns {:ok, profile_vector} or {:error, reason}
  """
  def compute_user_profile(user_id) do
    with {:ok, watched_content} <- get_watched_content_with_embeddings(user_id),
         {:ok, profile_vector} <- aggregate_profile(watched_content) do
      # Store profile in Qdrant for fast retrieval
      payload = %{
        user_id: user_id,
        content_count: length(watched_content),
        computed_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      case Qdrant.upsert_point(@user_profile_collection, user_id, profile_vector, payload) do
        {:ok, _} ->
          Logger.info("[UserAnalytics] Updated profile for user #{user_id}")
          {:ok, profile_vector}

        {:error, reason} ->
          # Log but don't fail - profile computation succeeded
          Logger.warning("[UserAnalytics] Failed to store profile: #{inspect(reason)}")
          {:ok, profile_vector}
      end
    end
  end

  @doc """
  Gets cached user profile vector, computing if needed.
  """
  def get_user_profile(user_id) do
    cache_key = "user_profile:#{user_id}"

    Cache.fetch(cache_key, @recommendations_ttl, fn ->
      fetch_or_compute_profile(user_id)
    end)
  end

  # ============================================================================
  # Personalized Recommendations
  # ============================================================================

  @doc """
  Gets personalized recommendations for a user.

  Uses their taste profile to find similar content they haven't watched.

  ## Options
  - `:limit` - Number of results (default: 20)
  - `:type` - Filter by content type ("movies", "series", "animes")
  - `:exclude_watched` - Exclude already watched (default: true)
  """
  def get_recommendations(user_id, opts \\ []) do
    cache_key = build_recommendations_key(user_id, opts)

    Cache.fetch(cache_key, @recommendations_ttl, fn ->
      case get_user_profile(user_id) do
        nil ->
          # No profile - return trending/popular instead
          {:ok, []}

        profile_vector ->
          search_recommendations(user_id, profile_vector, opts)
      end
    end)
  end

  @doc """
  Gets "Because you watched X" recommendations.

  Finds content similar to a specific watched item.
  """
  def get_similar_to(content_id, collection, opts \\ []) do
    limit = opts[:limit] || 10

    case Qdrant.find_similar(collection, content_id, limit: limit, score_threshold: 0.6) do
      {:ok, results} ->
        {:ok, format_recommendations(results)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets "You might also like" based on a specific content.

  Uses the content's embedding to find similar items.
  """
  def get_more_like_this(content, collection) do
    # Generate embedding for this content's metadata
    text = build_content_text(content)

    case Embeddings.embed(text) do
      {:ok, vector} ->
        # Search for similar, excluding this content
        filter = %{must_not: [%{has_id: [content.id]}]}

        case Qdrant.search(collection, vector, limit: 10, filter: filter) do
          {:ok, results} -> {:ok, format_recommendations(results)}
          error -> error
        end

      error ->
        error
    end
  end

  # ============================================================================
  # Channel Recommendations (AI-Powered)
  # ============================================================================

  @doc """
  Gets recommended live channels based on watch history.

  Uses a multi-signal approach:
  1. Category affinity from watched channels (via proper JOIN)
  2. Watch duration weighting (longer = stronger preference)
  3. Recency boost (recent watches matter more)
  4. Smart fallbacks for new users

  Returns {:ok, channels} with personalized channel recommendations.
  """
  def get_channel_recommendations(user_id, opts \\ []) do
    limit = opts[:limit] || 24

    # Get user's channel watch history
    history = History.list(user_id, content_type: "live_channel", limit: 100)

    case history do
      [] ->
        {:ok, get_popular_channels(limit)}

      history ->
        recommend_channels_from_history(history, limit)
    end
  end

  # Get popular public channels (fallback)
  defp get_popular_channels(limit, exclude_ids \\ []) do
    query =
      from(c in LiveChannel,
        join: p in Streamix.Iptv.Provider,
        on: c.provider_id == p.id,
        where: p.visibility in [:global, :public],
        where: not is_nil(c.stream_icon),
        order_by: c.name,
        limit: ^limit
      )

    query =
      if exclude_ids != [] do
        where(query, [c], c.id not in ^exclude_ids)
      else
        query
      end

    Repo.all(query)
  end

  # Compute category scores from watched channels with proper JOIN
  # Returns map of category_id => weighted_score
  defp compute_channel_category_scores(channel_ids, history) do
    # Build a map of channel_id => watch_weight from history
    channel_weights =
      Enum.reduce(history, %{}, fn entry, acc ->
        weight = calculate_watch_weight(entry)
        Map.update(acc, entry.content_id, weight, &(&1 + weight))
      end)

    # Get categories for watched channels via proper JOIN
    channel_categories =
      from(c in LiveChannel,
        join: ic in "item_categories",
        on: ic.catalog_item_id == c.catalog_item_id,
        join: cat in Streamix.Iptv.Category,
        on: ic.category_id == cat.id,
        where: c.id in ^channel_ids,
        select: {c.id, cat.id, cat.name}
      )
      |> Repo.all()

    # Aggregate scores by category_id
    Enum.reduce(channel_categories, %{}, fn {channel_id, category_id, _name}, acc ->
      weight = Map.get(channel_weights, channel_id, 1.0)
      Map.update(acc, category_id, weight, &(&1 + weight))
    end)
  end

  # Calculate watch weight based on duration and recency
  defp calculate_watch_weight(entry) do
    base = 1.0

    # Duration factor: longer watch = stronger preference (cap at 2x)
    duration = entry.duration_seconds || 60
    duration_factor = min(1 + duration / 3600, 2.0)

    # Recency factor: recent = stronger (exponential decay over 14 days)
    days_ago = DateTime.diff(DateTime.utc_now(), entry.watched_at, :day)
    recency_factor = :math.exp(-days_ago / 14)

    base * duration_factor * recency_factor
  end

  # ============================================================================
  # Personalized Content (AI-Powered Sections)
  # ============================================================================

  @doc """
  Gets personalized trending movies for user.

  Uses watch history to reorder trending by user's taste profile.
  Supports genre and period filters.

  ## Options
  - `:limit` - Number of results (default: 12)
  - `:genre` - Filter by genre ("all" | "action" | "comedy" | etc)
  - `:days` - Trending period (7 | 30 | nil for all time)
  """
  def get_personalized_trending(user_id, opts \\ []) do
    limit = opts[:limit] || 12
    genre = opts[:genre] || "all"
    days = opts[:days] || 7

    # Get base trending from catalog
    trending = Catalog.list_trending_movies(limit: limit * 2, days: days)

    trending
    |> filter_by_genre(genre)
    |> maybe_reorder_by_user_taste(user_id)
    |> Enum.take(limit)
  end

  @doc """
  Gets personalized series for user.

  Uses watch history to recommend series matching user's taste.

  ## Options
  - `:limit` - Number of results (default: 12)
  - `:genre` - Filter by genre
  - `:days` - Recent additions period
  """
  def get_personalized_series(user_id, opts \\ []) do
    limit = opts[:limit] || 12
    genre = opts[:genre] || "all"

    # Get base series from catalog
    Catalog.list_top_10_series(limit: limit * 2)
    |> filter_by_genre(genre)
    |> maybe_reorder_by_user_taste(user_id)
    |> Enum.take(limit)
  end

  @doc """
  Gets personalized channel recommendations with category filter.

  Uses AI-powered recommendations when available, with category filtering
  via proper database JOINs (not string matching on non-existent fields).

  ## Options
  - `:limit` - Number of results (default: 24)
  - `:category` - Filter by category name ("all" | "sports" | "movies" | "news" | "kids")
  """
  def get_personalized_channels(user_id, opts \\ []) do
    limit = opts[:limit] || 24
    category = opts[:category] || "all"

    if category == "all" do
      # No filter - use AI recommendations directly
      {:ok, channels} = get_channel_recommendations(user_id, limit: limit)
      channels
    else
      # Filter by category name using proper JOIN
      get_channels_by_category(user_id, category, limit)
    end
  end

  # Get channels filtered by category name with AI ordering
  defp get_channels_by_category(user_id, category_name, limit) do
    # First, get user's channel preferences for ordering
    history = History.list(user_id, content_type: "live_channel", limit: 50)
    watched_ids = Enum.map(history, & &1.content_id)

    # Query channels by category name (case-insensitive partial match)
    category_pattern = "%#{String.downcase(category_name)}%"

    channels =
      from(c in LiveChannel,
        join: ic in "item_categories",
        on: ic.catalog_item_id == c.catalog_item_id,
        join: cat in Streamix.Iptv.Category,
        on: ic.category_id == cat.id,
        join: p in Streamix.Iptv.Provider,
        on: c.provider_id == p.id,
        where: p.visibility in [:global, :public],
        where: fragment("LOWER(?)", cat.name) |> like(^category_pattern),
        where: not is_nil(c.stream_icon),
        order_by: c.name,
        limit: ^(limit * 2),
        distinct: true,
        select: c
      )
      |> Repo.all()

    # Order: put unwatched channels first (discovery), then watched
    channels
    |> Enum.sort_by(fn c -> if c.id in watched_ids, do: 1, else: 0 end)
    |> Enum.take(limit)
  end

  @doc """
  Gets user's favorite genres for dynamic filter options.

  Returns list of {value, label} tuples for dropdown.
  """
  def get_user_genre_filters(nil), do: default_genre_filters()

  def get_user_genre_filters(user_id) do
    case get_user_insights(user_id) do
      %{favorite_genres: [_ | _] = genres} ->
        # Prioritize user's favorite genres
        user_genres =
          genres
          |> Enum.take(3)
          |> Enum.map(fn g -> {String.downcase(g), g} end)

        [{"all", "Todos"}] ++ user_genres ++ [{"more", "Mais..."}]

      _ ->
        default_genre_filters()
    end
  end

  defp default_genre_filters do
    [
      {"all", "Todos"},
      {"action", "Ação"},
      {"comedy", "Comédia"},
      {"drama", "Drama"},
      {"horror", "Terror"},
      {"sci-fi", "Ficção"},
      {"animation", "Animação"}
    ]
  end

  @doc """
  Gets period filter options (static).
  """
  def get_period_filters do
    [
      {7, "7 dias"},
      {30, "30 dias"},
      {nil, "Todos"}
    ]
  end

  @doc """
  Gets channel category filters.
  """
  def get_channel_category_filters do
    [
      {"all", "Todos"},
      {"sports", "Esportes"},
      {"movies", "Filmes"},
      {"news", "Notícias"},
      {"kids", "Infantil"}
    ]
  end

  # ============================================================================
  # Analytics Insights
  # ============================================================================

  @doc """
  Gets viewing insights for a user.

  Returns aggregated stats about their viewing habits:
  - Favorite genres
  - Watch time patterns (weekday vs weekend, time of day)
  - Content type preferences
  - Completion rate
  """
  def get_user_insights(user_id) do
    cache_key = "user_insights:#{user_id}"

    Cache.fetch(cache_key, @recommendations_ttl, fn ->
      history = History.list(user_id, limit: 500)

      if Enum.empty?(history) do
        %{has_data: false}
      else
        %{
          has_data: true,
          total_items: length(history),
          content_breakdown: History.count_by_type(user_id),
          completion_rate: calculate_completion_rate(history),
          favorite_genres: extract_favorite_genres(user_id),
          watch_patterns: analyze_watch_patterns(history),
          most_watched_day: get_most_watched_day(history),
          avg_session_length: calculate_avg_session(history)
        }
      end
    end)
  end

  # ============================================================================
  # Content Indexing
  # ============================================================================

  @doc """
  Indexes a content item in Qdrant for recommendations.

  Call this after syncing content or enriching with TMDB data.
  """
  def index_content(content, collection) do
    text = build_content_text(content)

    case Embeddings.embed(text) do
      {:ok, vector} ->
        payload = %{
          title: content.name || content.title,
          year: Map.get(content, :year),
          genre: Map.get(content, :genre),
          rating: Map.get(content, :rating),
          provider_id: Map.get(content, :provider_id)
        }

        Qdrant.upsert_point(collection, content.id, vector, payload)

      {:error, reason} ->
        Logger.warning(
          "[UserAnalytics] Failed to embed content #{content.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Indexes multiple content items in batch.
  """
  def index_contents(contents, collection) do
    texts = Enum.map(contents, &build_content_text/1)

    case Embeddings.embed_batch(texts) do
      {:ok, vectors} ->
        points =
          Enum.zip(contents, vectors)
          |> Enum.map(fn {content, vector} ->
            payload = %{
              title: content.name || content.title,
              year: Map.get(content, :year),
              genre: Map.get(content, :genre),
              rating: Map.get(content, :rating),
              provider_id: Map.get(content, :provider_id)
            }

            {content.id, vector, payload}
          end)

        Qdrant.upsert_points(collection, points)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_watched_content_with_embeddings(user_id) do
    history = History.list(user_id, limit: 100)

    case history do
      [] ->
        {:error, :no_history}

      history ->
        case map_embeddings(history) do
          [] -> {:error, :no_embeddings}
          content_with_vectors -> {:ok, content_with_vectors}
        end
    end
  end

  defp aggregate_profile(content_with_vectors) do
    # Weighted average of all vectors
    total_weight = Enum.reduce(content_with_vectors, 0, fn %{weight: w}, acc -> acc + w end)

    case total_weight do
      0 ->
        {:error, :zero_weight}

      _ ->
        dimensions = length(hd(content_with_vectors).vector)
        profile = weighted_profile(content_with_vectors, dimensions, total_weight)
        {:ok, profile}
    end
  end

  defp calculate_weight(entry) do
    base_weight = 1.0

    # Recency: more recent = higher weight
    days_ago = DateTime.diff(DateTime.utc_now(), entry.watched_at, :day)
    # Decay over 30 days
    recency_factor = :math.exp(-days_ago / 30)

    # Completion: completed = 1.5x weight
    completion_factor = if entry.completed, do: 1.5, else: 1.0

    # Watch time: longer sessions = higher weight
    duration = entry.duration_seconds || 0
    # Cap at 2x
    duration_factor = min(1 + duration / 3600, 2.0)

    base_weight * recency_factor * completion_factor * duration_factor
  end

  defp content_type_to_collection("movie"), do: "movies"
  defp content_type_to_collection("episode"), do: "series"
  defp content_type_to_collection("live_channel"), do: "movies"
  defp content_type_to_collection(_), do: "movies"

  defp get_watched_content_ids(user_id, collection) do
    content_type = collection_to_content_type(collection)

    History.list(user_id, content_type: content_type, limit: 500)
    |> Enum.map(& &1.content_id)
  end

  defp collection_to_content_type("movies"), do: "movie"
  defp collection_to_content_type("series"), do: "episode"
  defp collection_to_content_type(_), do: "movie"

  defp build_content_text(content) do
    parts = [
      content.name || content.title,
      Map.get(content, :plot),
      Map.get(content, :genre),
      Map.get(content, :cast),
      Map.get(content, :director)
    ]

    parts
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp fetch_or_compute_profile(user_id) do
    case Qdrant.get_point(@user_profile_collection, user_id) do
      {:ok, %{vector: vector}} -> vector
      {:error, :not_found} -> compute_profile_vector(user_id)
      {:error, _} -> nil
    end
  end

  defp compute_profile_vector(user_id) do
    case compute_user_profile(user_id) do
      {:ok, vector} -> vector
      {:error, _} -> nil
    end
  end

  defp search_recommendations(user_id, profile_vector, opts) do
    collection = opts[:type] || "movies"
    limit = opts[:limit] || 20
    exclude_watched = Keyword.get(opts, :exclude_watched, true)
    search_opts = build_search_opts(user_id, collection, limit, exclude_watched)

    case Qdrant.search(collection, profile_vector, search_opts) do
      {:ok, results} ->
        format_recommendations(results)

      {:error, reason} ->
        Logger.warning("[UserAnalytics] Recommendation search failed: #{inspect(reason)}")
        []
    end
  end

  defp build_search_opts(user_id, collection, limit, exclude_watched) do
    search_opts = [limit: limit, score_threshold: 0.5]

    case build_exclusion_filter(user_id, collection, exclude_watched) do
      nil -> search_opts
      filter -> Keyword.put(search_opts, :filter, filter)
    end
  end

  defp build_exclusion_filter(_user_id, _collection, false), do: nil

  defp build_exclusion_filter(user_id, collection, true) do
    case get_watched_content_ids(user_id, collection) do
      [] -> nil
      watched_ids -> %{must_not: [%{has_id: watched_ids}]}
    end
  end

  defp recommend_channels_from_history(history, limit) do
    watched_channel_ids = Enum.map(history, & &1.content_id)
    category_scores = compute_channel_category_scores(watched_channel_ids, history)

    case category_scores do
      scores when map_size(scores) == 0 ->
        {:ok, get_popular_channels(limit)}

      scores ->
        top_category_ids = top_category_ids(scores)
        recommended = recommended_channels(top_category_ids, watched_channel_ids, limit)
        {:ok, fill_channel_recommendations(recommended, watched_channel_ids, limit)}
    end
  end

  defp top_category_ids(category_scores) do
    category_scores
    |> Enum.sort_by(fn {_id, score} -> score end, :desc)
    |> Enum.take(10)
    |> Enum.map(fn {id, _score} -> id end)
  end

  defp recommended_channels(top_category_ids, watched_channel_ids, limit) do
    from(c in LiveChannel,
      join: ic in "item_categories",
      on: ic.catalog_item_id == c.catalog_item_id,
      join: p in Streamix.Iptv.Provider,
      on: c.provider_id == p.id,
      where: p.visibility in [:global, :public],
      where: ic.category_id in ^top_category_ids,
      where: c.id not in ^watched_channel_ids,
      where: not is_nil(c.stream_icon),
      limit: ^(limit * 3),
      select: c
    )
    |> Repo.all()
    |> Enum.uniq_by(& &1.id)
    |> Enum.shuffle()
    |> Enum.take(limit)
  end

  defp fill_channel_recommendations(recommended, watched_channel_ids, limit) do
    case recommended do
      channels when length(channels) < limit ->
        remaining = limit - length(channels)
        exclude_ids = watched_channel_ids ++ Enum.map(channels, & &1.id)
        channels ++ get_popular_channels(remaining, exclude_ids)

      channels ->
        channels
    end
  end

  defp filter_by_genre(items, "all"), do: items

  defp filter_by_genre(items, genre) do
    downcased_genre = String.downcase(genre)

    Enum.filter(items, fn item ->
      item_genre_str = Streamix.Helpers.genre_names(Map.get(item, :genres, [])) || ""

      item_genre_str
      |> String.downcase()
      |> String.contains?(downcased_genre)
    end)
  end

  defp maybe_reorder_by_user_taste(items, user_id) do
    case get_user_profile(user_id) do
      nil -> items
      _profile_vector -> reorder_by_favorite_genres(items, user_id)
    end
  end

  defp reorder_by_favorite_genres(items, user_id) do
    favorite_genres = user_id |> get_user_insights() |> Map.get(:favorite_genres, [])
    Enum.sort_by(items, &genre_priority(&1, favorite_genres))
  end

  defp genre_priority(item, favorite_genres) do
    item_genre = Streamix.Helpers.genre_names(Map.get(item, :genres, [])) || ""
    if matches_favorite_genre?(item_genre, favorite_genres), do: 0, else: 1
  end

  defp matches_favorite_genre?(item_genre, favorite_genres) do
    item_genre = String.downcase(item_genre)

    Enum.any?(favorite_genres, fn genre ->
      String.contains?(item_genre, String.downcase(genre))
    end)
  end

  defp map_embeddings(history) do
    Enum.reduce(history, [], fn entry, acc ->
      case Qdrant.get_point(content_type_to_collection(entry.content_type), entry.content_id) do
        {:ok, %{vector: vector}} ->
          [%{vector: vector, weight: calculate_weight(entry)} | acc]

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp weighted_profile(content_with_vectors, dimensions, total_weight) do
    Enum.reduce(content_with_vectors, List.duplicate(0.0, dimensions), fn %{
                                                                            vector: vec,
                                                                            weight: weight
                                                                          },
                                                                          acc ->
      apply_weighted_vector(acc, vec, weight, total_weight)
    end)
  end

  defp apply_weighted_vector(acc, vector, weight, total_weight) do
    acc
    |> Enum.zip(vector)
    |> Enum.map(fn {current, value} -> current + value * weight / total_weight end)
  end

  defp format_recommendations(results) do
    Enum.map(results, fn %{id: id, score: score, payload: payload} ->
      %{
        id: id,
        score: Float.round(score, 3),
        title: payload["title"],
        year: payload["year"],
        genre: payload["genre"],
        rating: payload["rating"]
      }
    end)
  end

  defp build_recommendations_key(user_id, opts) do
    type = opts[:type] || "movies"
    limit = opts[:limit] || 20
    "recommendations:#{user_id}:#{type}:#{limit}"
  end

  defp calculate_completion_rate(history) do
    if Enum.empty?(history) do
      0.0
    else
      completed = Enum.count(history, & &1.completed)
      Float.round(completed / length(history) * 100, 1)
    end
  end

  defp extract_favorite_genres(user_id) do
    # Get movies watched and extract genres via join table
    history = History.list(user_id, content_type: "movie", limit: 100)
    movie_ids = Enum.map(history, & &1.content_id)

    if Enum.empty?(movie_ids) do
      []
    else
      Genre
      |> join(:inner, [g], mg in "movie_genres", on: mg.genre_id == g.id)
      |> where([g, mg], mg.movie_id in ^movie_ids)
      |> select([g, _mg], g.name)
      |> Repo.all()
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_, count} -> count end, :desc)
      |> Enum.take(5)
      |> Enum.map(fn {genre, _} -> genre end)
    end
  end

  defp analyze_watch_patterns(history) do
    # Analyze by hour of day
    by_hour =
      history
      |> Enum.group_by(fn entry -> entry.watched_at.hour end)
      |> Enum.map(fn {hour, entries} -> {hour, length(entries)} end)
      |> Enum.sort_by(fn {_, count} -> count end, :desc)

    peak_hour =
      case by_hour do
        [{hour, _} | _] -> hour
        _ -> nil
      end

    # Analyze by day of week
    by_day =
      history
      |> Enum.group_by(fn entry -> Date.day_of_week(DateTime.to_date(entry.watched_at)) end)
      |> Enum.map(fn {day, entries} -> {day, length(entries)} end)

    weekend_count =
      Enum.filter(by_day, fn {day, _} -> day in [6, 7] end)
      |> Enum.reduce(0, fn {_, c}, acc -> acc + c end)

    weekday_count =
      Enum.filter(by_day, fn {day, _} -> day in [1, 2, 3, 4, 5] end)
      |> Enum.reduce(0, fn {_, c}, acc -> acc + c end)

    %{
      peak_hour: peak_hour,
      weekend_preference: weekend_count > weekday_count,
      weekday_count: weekday_count,
      weekend_count: weekend_count
    }
  end

  defp get_most_watched_day(history) do
    history
    |> Enum.group_by(fn entry -> Date.day_of_week(DateTime.to_date(entry.watched_at)) end)
    |> Enum.max_by(fn {_, entries} -> length(entries) end, fn -> {1, []} end)
    |> elem(0)
    |> day_number_to_name()
  end

  defp day_number_to_name(1), do: "Segunda"
  defp day_number_to_name(2), do: "Terça"
  defp day_number_to_name(3), do: "Quarta"
  defp day_number_to_name(4), do: "Quinta"
  defp day_number_to_name(5), do: "Sexta"
  defp day_number_to_name(6), do: "Sábado"
  defp day_number_to_name(7), do: "Domingo"
  defp day_number_to_name(_), do: "Desconhecido"

  defp calculate_avg_session(history) do
    durations = Enum.map(history, & &1.duration_seconds) |> Enum.reject(&is_nil/1)

    if Enum.empty?(durations) do
      0
    else
      avg = Enum.sum(durations) / length(durations)
      # Return in minutes
      round(avg / 60)
    end
  end
end
