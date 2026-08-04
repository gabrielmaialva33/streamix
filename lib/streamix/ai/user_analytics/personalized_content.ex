defmodule Streamix.AI.UserAnalytics.PersonalizedContent do
  @moduledoc false

  alias Streamix.AI.UserAnalytics.Insights
  alias Streamix.AI.UserAnalytics.Profile
  alias Streamix.Iptv.Catalog

  @doc """
  Gets personalized trending movies for user.

  Uses watch history to reorder trending by user's taste profile.
  Supports genre and period filters.

  ## Options
  - `:limit` - Number of results (default: 12)
  - `:genre` - Filter by genre ("all" | "action" | "comedy" | etc)
  - `:days` - Trending period (7 | 30 | nil for all time)
  - `:show_adult` - Include adult content (default: false)
  """
  def get_personalized_trending(user_id, opts \\ []) do
    limit = opts[:limit] || 12
    genre = opts[:genre] || "all"
    days = opts[:days] || 7
    show_adult = Keyword.get(opts, :show_adult, false)

    Catalog.list_trending_movies(limit: limit * 2, days: days, show_adult: show_adult)
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

    Catalog.list_top_10_series(limit: limit * 2)
    |> filter_by_genre(genre)
    |> maybe_reorder_by_user_taste(user_id)
    |> Enum.take(limit)
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
    case Profile.get_user_profile(user_id) do
      nil -> items
      _profile_vector -> reorder_by_favorite_genres(items, user_id)
    end
  end

  defp reorder_by_favorite_genres(items, user_id) do
    favorite_genres = user_id |> Insights.get_user_insights() |> Map.get(:favorite_genres, [])
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
end
