defmodule Streamix.AI.UserAnalytics.Channels do
  @moduledoc false

  alias Streamix.Iptv
  alias Streamix.Library

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
    show_adult = Keyword.get(opts, :show_adult, false)

    history =
      Library.list_watch_history_for_analytics(user_id,
        content_type: "live_channel",
        limit: 100,
        show_adult: show_adult
      )

    case history do
      [] ->
        {:ok, get_popular_channels(user_id, limit, [], show_adult)}

      history ->
        recommend_channels_from_history(user_id, history, limit, show_adult)
    end
  end

  @doc """
  Gets personalized channel recommendations with category filter.

  Uses AI-powered recommendations when available, with category filtering
  via proper database JOINs.

  ## Options
  - `:limit` - Number of results (default: 24)
  - `:category` - Filter by category name ("all" | "sports" | "movies" | "news" | "kids")
  """
  def get_personalized_channels(user_id, opts \\ []) do
    limit = opts[:limit] || 24
    category = opts[:category] || "all"
    show_adult = Keyword.get(opts, :show_adult, false)

    if category == "all" do
      {:ok, channels} =
        get_channel_recommendations(user_id, limit: limit, show_adult: show_adult)

      channels
    else
      get_channels_by_category(user_id, category, limit, show_adult)
    end
  end

  defp get_popular_channels(user_id, limit, exclude_ids, show_adult) do
    user_id
    |> Iptv.list_channel_recommendation_candidates(
      limit: limit,
      exclude_ids: exclude_ids,
      show_adult: show_adult
    )
    |> stable_channels()
  end

  defp compute_channel_category_scores(channel_ids, history) do
    channel_weights =
      Enum.reduce(history, %{}, fn entry, acc ->
        weight = calculate_watch_weight(entry)
        Map.update(acc, entry.content_id, weight, &(&1 + weight))
      end)

    channel_categories = Iptv.channel_recommendation_category_refs(channel_ids)

    Enum.reduce(channel_categories, %{}, fn {channel_id, category_id}, acc ->
      weight = Map.get(channel_weights, channel_id, 1.0)
      Map.update(acc, category_id, weight, &(&1 + weight))
    end)
  end

  defp calculate_watch_weight(entry) do
    base = 1.0
    duration = entry.duration_seconds || 60
    duration_factor = min(1 + duration / 3600, 2.0)
    days_ago = DateTime.diff(DateTime.utc_now(), entry.watched_at, :day)
    recency_factor = :math.exp(-days_ago / 14)

    base * duration_factor * recency_factor
  end

  defp get_channels_by_category(user_id, category_name, limit, show_adult) do
    history =
      Library.list_watch_history_for_analytics(user_id,
        content_type: "live_channel",
        limit: 50,
        show_adult: show_adult
      )

    watched_ids = Enum.map(history, & &1.content_id)

    channels =
      Iptv.list_channel_recommendation_candidates(user_id,
        category_name: category_name,
        limit: limit * 2,
        show_adult: show_adult
      )

    channels
    |> Enum.sort_by(fn channel ->
      {if(channel.id in watched_ids, do: 1, else: 0), normalized_name(channel), channel.id}
    end)
    |> Enum.take(limit)
  end

  defp recommend_channels_from_history(user_id, history, limit, show_adult) do
    watched_channel_ids = Enum.map(history, & &1.content_id)
    category_scores = compute_channel_category_scores(watched_channel_ids, history)

    case category_scores do
      scores when map_size(scores) == 0 ->
        {:ok, get_popular_channels(user_id, limit, [], show_adult)}

      scores ->
        top_category_ids = top_category_ids(scores)

        recommended =
          recommended_channels(
            user_id,
            top_category_ids,
            category_scores,
            watched_channel_ids,
            limit,
            show_adult
          )

        {:ok,
         fill_channel_recommendations(
           user_id,
           recommended,
           watched_channel_ids,
           limit,
           show_adult
         )}
    end
  end

  defp top_category_ids(category_scores) do
    category_scores
    |> Enum.sort_by(fn {_id, score} -> score end, :desc)
    |> Enum.take(10)
    |> Enum.map(fn {id, _score} -> id end)
  end

  defp recommended_channels(
         user_id,
         top_category_ids,
         category_scores,
         watched_channel_ids,
         limit,
         show_adult
       ) do
    candidates =
      Iptv.list_channel_recommendation_candidates(user_id,
        category_ids: top_category_ids,
        exclude_ids: watched_channel_ids,
        limit: limit * 3,
        show_adult: show_adult
      )

    category_refs =
      candidates
      |> Enum.map(& &1.id)
      |> Iptv.channel_recommendation_category_refs()

    candidates
    |> rank_candidates(category_scores, category_refs)
    |> Enum.take(limit)
  end

  @doc "Ranks channel candidates by watched-category affinity with stable tie-breakers."
  @spec rank_candidates([map()], map(), [{integer(), integer()}]) :: [map()]
  def rank_candidates(channels, category_scores, category_refs) do
    affinity_by_channel =
      Enum.reduce(category_refs, %{}, fn {channel_id, category_id}, acc ->
        score = Map.get(category_scores, category_id, 0.0)
        Map.update(acc, channel_id, score, &(&1 + score))
      end)

    Enum.sort_by(channels, fn channel ->
      {-Map.get(affinity_by_channel, channel.id, 0.0), normalized_name(channel), channel.id}
    end)
  end

  defp stable_channels(channels) do
    Enum.sort_by(channels, &{normalized_name(&1), &1.id})
  end

  defp normalized_name(channel) do
    channel
    |> Map.get(:name, "")
    |> to_string()
    |> String.downcase()
  end

  defp fill_channel_recommendations(
         user_id,
         recommended,
         watched_channel_ids,
         limit,
         show_adult
       ) do
    case recommended do
      channels when length(channels) < limit ->
        remaining = limit - length(channels)
        exclude_ids = watched_channel_ids ++ Enum.map(channels, & &1.id)
        channels ++ get_popular_channels(user_id, remaining, exclude_ids, show_adult)

      channels ->
        channels
    end
  end
end
