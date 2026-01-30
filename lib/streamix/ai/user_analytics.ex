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

  alias Streamix.AI.{Embeddings, Qdrant}
  alias Streamix.Iptv.{History, Movie, Channel}
  alias Streamix.{Cache, Repo}

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
      case Qdrant.get_point(@user_profile_collection, user_id) do
        {:ok, %{vector: vector}} ->
          vector

        {:error, :not_found} ->
          case compute_user_profile(user_id) do
            {:ok, vector} -> vector
            {:error, _} -> nil
          end

        {:error, _} ->
          nil
      end
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
          collection = opts[:type] || "movies"
          limit = opts[:limit] || 20
          exclude_watched = Keyword.get(opts, :exclude_watched, true)

          # Build filter to exclude already watched content
          filter = if exclude_watched do
            watched_ids = get_watched_content_ids(user_id, collection)
            if Enum.empty?(watched_ids) do
              nil
            else
              %{must_not: [%{has_id: watched_ids}]}
            end
          else
            nil
          end

          search_opts = [limit: limit, score_threshold: 0.5]
          search_opts = if filter, do: Keyword.put(search_opts, :filter, filter), else: search_opts

          case Qdrant.search(collection, profile_vector, search_opts) do
            {:ok, results} ->
              format_recommendations(results)

            {:error, reason} ->
              Logger.warning("[UserAnalytics] Recommendation search failed: #{inspect(reason)}")
              []
          end
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
  # Channel Recommendations
  # ============================================================================

  @doc """
  Gets recommended live channels based on watch history.

  Analyzes which channel categories user watches most and recommends similar.
  """
  def get_channel_recommendations(user_id, opts \\ []) do
    limit = opts[:limit] || 10

    # Get user's channel watch history
    history = History.list(user_id, content_type: "live_channel", limit: 100)

    if Enum.empty?(history) do
      {:ok, []}
    else
      # Extract category patterns from watched channels
      category_scores = compute_category_affinity(history)

      # Get top categories
      top_categories =
        category_scores
        |> Enum.sort_by(fn {_, score} -> score end, :desc)
        |> Enum.take(5)
        |> Enum.map(fn {cat, _} -> cat end)

      # Find channels in those categories user hasn't watched
      watched_ids = Enum.map(history, & &1.content_id)

      recommended =
        Channel
        |> where([c], c.category in ^top_categories)
        |> where([c], c.id not in ^watched_ids)
        |> order_by([c], asc: fragment("RANDOM()"))
        |> limit(^limit)
        |> Repo.all()

      {:ok, recommended}
    end
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
        Logger.warning("[UserAnalytics] Failed to embed content #{content.id}: #{inspect(reason)}")
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

    if Enum.empty?(history) do
      {:error, :no_history}
    else
      # Group by content type and fetch embeddings
      content_with_vectors =
        history
        |> Enum.map(fn entry ->
          collection = content_type_to_collection(entry.content_type)
          weight = calculate_weight(entry)

          case Qdrant.get_point(collection, entry.content_id) do
            {:ok, %{vector: vector}} ->
              %{vector: vector, weight: weight}

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      if Enum.empty?(content_with_vectors) do
        {:error, :no_embeddings}
      else
        {:ok, content_with_vectors}
      end
    end
  end

  defp aggregate_profile(content_with_vectors) do
    # Weighted average of all vectors
    total_weight = Enum.reduce(content_with_vectors, 0, fn %{weight: w}, acc -> acc + w end)

    if total_weight == 0 do
      {:error, :zero_weight}
    else
      dimensions = length(hd(content_with_vectors).vector)

      profile =
        Enum.reduce(content_with_vectors, List.duplicate(0.0, dimensions), fn %{vector: vec, weight: w}, acc ->
          Enum.zip(acc, vec)
          |> Enum.map(fn {a, v} -> a + v * w / total_weight end)
        end)

      {:ok, profile}
    end
  end

  defp calculate_weight(entry) do
    base_weight = 1.0

    # Recency: more recent = higher weight
    days_ago = DateTime.diff(DateTime.utc_now(), entry.watched_at, :day)
    recency_factor = :math.exp(-days_ago / 30) # Decay over 30 days

    # Completion: completed = 1.5x weight
    completion_factor = if entry.completed, do: 1.5, else: 1.0

    # Watch time: longer sessions = higher weight
    duration = entry.duration_seconds || 0
    duration_factor = min(1 + duration / 3600, 2.0) # Cap at 2x

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
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
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

  defp compute_category_affinity(history) do
    # Count watch time per category
    Enum.reduce(history, %{}, fn entry, acc ->
      category = entry.parent_name || "Unknown"
      duration = entry.duration_seconds || 60

      Map.update(acc, category, duration, &(&1 + duration))
    end)
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
    # Get movies watched and extract genres
    history = History.list(user_id, content_type: "movie", limit: 100)
    movie_ids = Enum.map(history, & &1.content_id)

    if Enum.empty?(movie_ids) do
      []
    else
      Movie
      |> where([m], m.id in ^movie_ids)
      |> select([m], m.genre)
      |> Repo.all()
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&String.split(&1, ", "))
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

    peak_hour = case by_hour do
      [{hour, _} | _] -> hour
      _ -> nil
    end

    # Analyze by day of week
    by_day =
      history
      |> Enum.group_by(fn entry -> Date.day_of_week(DateTime.to_date(entry.watched_at)) end)
      |> Enum.map(fn {day, entries} -> {day, length(entries)} end)

    weekend_count = Enum.filter(by_day, fn {day, _} -> day in [6, 7] end)
                    |> Enum.reduce(0, fn {_, c}, acc -> acc + c end)
    weekday_count = Enum.filter(by_day, fn {day, _} -> day in [1, 2, 3, 4, 5] end)
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
      round(avg / 60) # Return in minutes
    end
  end
end
