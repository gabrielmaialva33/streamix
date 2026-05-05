defmodule Streamix.AI.UserAnalytics.Channels do
  @moduledoc false

  alias Streamix.Iptv.History
  alias Streamix.Iptv.LiveChannel
  alias Streamix.Repo

  import Ecto.Query

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
    history = History.list_for_analytics(user_id, content_type: "live_channel", limit: 100)

    case history do
      [] ->
        {:ok, get_popular_channels(limit)}

      history ->
        recommend_channels_from_history(history, limit)
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

    if category == "all" do
      {:ok, channels} = get_channel_recommendations(user_id, limit: limit)
      channels
    else
      get_channels_by_category(user_id, category, limit)
    end
  end

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

  defp compute_channel_category_scores(channel_ids, history) do
    channel_weights =
      Enum.reduce(history, %{}, fn entry, acc ->
        weight = calculate_watch_weight(entry)
        Map.update(acc, entry.content_id, weight, &(&1 + weight))
      end)

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

    Enum.reduce(channel_categories, %{}, fn {channel_id, category_id, _name}, acc ->
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

  defp get_channels_by_category(user_id, category_name, limit) do
    history = History.list_for_analytics(user_id, content_type: "live_channel", limit: 50)
    watched_ids = Enum.map(history, & &1.content_id)
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

    channels
    |> Enum.sort_by(fn channel -> if channel.id in watched_ids, do: 1, else: 0 end)
    |> Enum.take(limit)
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
end
