defmodule Streamix.AI.UserAnalytics.Recommendations do
  @moduledoc false

  require Logger

  alias Streamix.AI.Embeddings
  alias Streamix.AI.Qdrant
  alias Streamix.AI.UserAnalytics.Content
  alias Streamix.AI.UserAnalytics.Formatter
  alias Streamix.AI.UserAnalytics.Profile
  alias Streamix.Cache
  alias Streamix.Iptv.History

  @recommendations_ttl 3600

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
      case Profile.get_user_profile(user_id) do
        nil ->
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
        {:ok, Formatter.recommendations(results)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets "You might also like" based on a specific content.

  Uses the content's embedding to find similar items.
  """
  def get_more_like_this(content, collection) do
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

  defp search_recommendations(user_id, profile_vector, opts) do
    collection = opts[:type] || "movies"
    limit = opts[:limit] || 20
    exclude_watched = Keyword.get(opts, :exclude_watched, true)
    search_opts = build_search_opts(user_id, collection, limit, exclude_watched)

    case Qdrant.search(collection, profile_vector, search_opts) do
      {:ok, results} ->
        Formatter.recommendations(results)

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

  defp get_watched_content_ids(user_id, collection) do
    content_type = collection_to_content_type(collection)

    History.list_for_analytics(user_id, content_type: content_type, limit: 500)
    |> Enum.map(& &1.content_id)
  end

  defp collection_to_content_type("movies"), do: "movie"
  defp collection_to_content_type("series"), do: "episode"
  defp collection_to_content_type(_), do: "movie"

  defp build_recommendations_key(user_id, opts) do
    type = opts[:type] || "movies"
    limit = opts[:limit] || 20
    "recommendations:#{user_id}:#{type}:#{limit}"
  end
end
