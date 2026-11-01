defmodule Streamix.AI.UserAnalytics.Recommendations do
  @moduledoc false

  require Logger

  alias Streamix.Accounts
  alias Streamix.AI.Embeddings
  alias Streamix.AI.Qdrant
  alias Streamix.AI.ScoreThresholds
  alias Streamix.AI.UserAnalytics.Content
  alias Streamix.AI.UserAnalytics.Formatter
  alias Streamix.AI.UserAnalytics.Profile
  alias Streamix.Cache
  alias Streamix.Library
  alias Streamix.Library.Key

  @recommendations_ttl :timer.hours(1)
  @content_collections ~w(movies series)

  @doc """
  Gets personalized recommendations for a user.

  Uses their taste profile to find similar content they haven't watched.

  ## Options
  - `:limit` - Number of results (default: 20)
  - `:type` - Filter by content type ("movies", "series", "animes")
  - `:exclude_watched` - Exclude already watched (default: true)

  The result reflects the sealed history, so it needs the user's library key
  and is only cached in this node's memory.
  """
  def get_recommendations(%Key{} = key, opts \\ []) do
    collection = Keyword.get(opts, :type, "movies")

    if collection in @content_collections do
      fetch_recommendations(key, opts)
    else
      {:error, :invalid_collection}
    end
  end

  defp fetch_recommendations(%Key{user_id: user_id} = key, opts) do
    Cache.fetch_personal(user_id, recommendations_cache_kind(opts), @recommendations_ttl, fn ->
      recommend_for_profile(resolve_profile(key, opts), key, opts)
    end)
  end

  defp recommend_for_profile(nil, _key, _opts), do: {:ok, []}

  defp recommend_for_profile(profile_vector, key, opts) do
    search_recommendations(key, profile_vector, opts)
  end

  defp resolve_profile(key, opts) do
    case Keyword.fetch(opts, :profile) do
      {:ok, profile} -> profile
      :error -> Profile.get_user_profile(key)
    end
  end

  @doc """
  Gets "Because you watched X" recommendations.

  Finds content similar to a specific watched item.
  """
  def get_similar_to(content_id, collection, opts \\ []) do
    limit = opts[:limit] || 10

    with true <- collection in @content_collections,
         {:ok, results} <-
           Qdrant.find_similar(collection, content_id,
             limit: limit,
             score_threshold: ScoreThresholds.similar()
           ) do
      {:ok, Formatter.recommendations(results)}
    else
      false ->
        {:error, :invalid_collection}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets "You might also like" based on a specific content.

  Uses the content's embedding to find similar items.
  """
  def get_more_like_this(content, collection) do
    if collection in @content_collections do
      do_get_more_like_this(content, collection)
    else
      {:error, :invalid_collection}
    end
  end

  defp do_get_more_like_this(content, collection) do
    text = Content.text(content)

    case Embeddings.embed(text) do
      {:ok, vector} ->
        filter = %{must_not: [%{has_id: [content.id]}]}

        case Qdrant.search(collection, vector, limit: 10, filter: filter) do
          {:ok, results} -> {:ok, Formatter.recommendations(results)}
          error -> error
        end

      error ->
        error
    end
  end

  defp search_recommendations(%Key{user_id: user_id} = key, profile_vector, opts) do
    collection = opts[:type] || "movies"
    limit = opts[:limit] || 20
    exclude_watched = Keyword.get(opts, :exclude_watched, true)
    search_opts = build_search_opts(key, collection, limit, exclude_watched)

    case Qdrant.search(collection, profile_vector, search_opts) do
      {:ok, results} ->
        Formatter.recommendations(results)

      {:error, reason} ->
        # Emit telemetry so the dashboard can distinguish "no results
        # for this user" (legit) from "Qdrant is sad" (incident). The
        # outer caller still gets a list so the UI degrades to "no
        # recommendations" instead of crashing.
        Logger.warning("[UserAnalytics] Recommendation search failed: #{inspect(reason)}")

        :telemetry.execute(
          [:streamix, :recommendations, :search_failed],
          %{count: 1},
          %{user_id: user_id, collection: collection, reason: reason}
        )

        []
    end
  end

  defp build_search_opts(key, collection, limit, exclude_watched) do
    search_opts = [limit: limit, score_threshold: ScoreThresholds.profile()]

    case build_exclusion_filter(key, collection, exclude_watched) do
      nil -> search_opts
      filter -> Keyword.put(search_opts, :filter, filter)
    end
  end

  defp build_exclusion_filter(_key, _collection, false), do: nil

  defp build_exclusion_filter(key, collection, true) do
    case get_watched_content_ids(key, collection) do
      [] -> nil
      watched_ids -> %{must_not: [%{has_id: watched_ids}]}
    end
  end

  defp get_watched_content_ids(%Key{user_id: user_id} = key, collection) do
    content_type = collection_to_content_type(collection)

    Library.list_watch_history_for_analytics(key,
      content_type: content_type,
      limit: 500,
      show_adult: show_adult_content?(user_id)
    )
    |> Enum.map(&recommendation_content_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp collection_to_content_type("movies"), do: "movie"
  defp collection_to_content_type("series"), do: "episode"
  defp collection_to_content_type(_), do: "movie"

  defp recommendations_cache_kind(opts) do
    type = opts[:type] || "movies"
    limit = opts[:limit] || 20
    exclude_watched = Keyword.get(opts, :exclude_watched, true)
    {:recommendations, type, limit, exclude_watched}
  end

  defp recommendation_content_id(%{content_type: "episode", series_id: series_id}),
    do: series_id

  defp recommendation_content_id(entry), do: entry.content_id

  defp show_adult_content?(user_id) do
    case Accounts.get_user(user_id, preload_role: false) do
      %{show_adult_content: value} -> value
      nil -> false
    end
  end
end
