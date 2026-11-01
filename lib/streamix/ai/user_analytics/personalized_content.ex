defmodule Streamix.AI.UserAnalytics.PersonalizedContent do
  @moduledoc false

  alias Streamix.AI.UserAnalytics.Insights
  alias Streamix.AI.UserAnalytics.Profile
  alias Streamix.Catalog
  alias Streamix.Library.Key

  @doc """
  Gets personalized trending movies for user.

  Uses watch history to reorder trending by user's taste profile.
  Supports genre and period filters.

  ## Options
  - `:limit` - Number of results (default: 12)
  - `:genre` - Filter by genre ("all" | "acao" | "comedia" | etc)
  - `:days` - Trending period (7 | 30 | nil for all time)
  - `:show_adult` - Include adult content (default: false)
  """
  def get_personalized_trending(%Key{} = key, opts \\ []) do
    limit = opts[:limit] || 12
    genre = opts[:genre] || "all"
    days = Keyword.get(opts, :days, 7)
    show_adult = Keyword.get(opts, :show_adult, false)

    Catalog.list_trending_movies(limit: limit * 2, days: days, show_adult: show_adult)
    |> filter_by_genre(genre)
    |> maybe_reorder_by_user_taste(key, personalization_input(opts))
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
  def get_personalized_series(%Key{} = key, opts \\ []) do
    limit = opts[:limit] || 12
    genre = opts[:genre] || "all"
    show_adult = Keyword.get(opts, :show_adult, false)

    Catalog.list_top_10_series(limit: limit * 2, show_adult: show_adult)
    |> filter_by_genre(genre)
    |> maybe_reorder_by_user_taste(key, personalization_input(opts))
    |> Enum.take(limit)
  end

  defp filter_by_genre(items, genre) when genre in ["all", nil, ""], do: items

  defp filter_by_genre(items, genre) when is_binary(genre) do
    Enum.filter(items, fn item ->
      genre in item_slugs(item)
    end)
  end

  defp personalization_input(opts) do
    %{
      profile: Keyword.get(opts, :profile, :fetch),
      insights: Keyword.get(opts, :insights, :fetch),
      semantic_scores: Keyword.get(opts, :semantic_scores, %{}),
      current_year: Keyword.get(opts, :current_year, Date.utc_today().year)
    }
  end

  defp maybe_reorder_by_user_taste(items, key, input) do
    profile = resolve_profile(input.profile, key)
    insights = resolve_insights(input.insights, key)

    if personalization_available?(profile, insights, input.semantic_scores) do
      rank_items(items, insights, input.semantic_scores, current_year: input.current_year)
    else
      items
    end
  end

  @doc """
  Ranks a candidate shelf with stable, explainable signals.

  Semantic similarity carries most of the score, while genre affinity,
  source metadata quality, recency, and the upstream list order keep the
  result useful when vector coverage is incomplete. The original index and
  content id are final deterministic tie-breakers.
  """
  @spec rank_items([map()], map(), map(), keyword()) :: [map()]
  def rank_items(items, insights, semantic_scores, opts \\ []) when is_list(items) do
    favorite_genres = Map.get(insights || %{}, :favorite_genres, [])
    favorite_slugs = favorite_genres |> Catalog.genre_slugs_all() |> MapSet.new()
    current_year = Keyword.get(opts, :current_year, Date.utc_today().year)
    count = max(length(items), 1)

    items
    |> Enum.with_index()
    |> Enum.sort_by(fn {item, index} ->
      score =
        hybrid_score(
          item,
          index,
          count,
          favorite_slugs,
          semantic_scores || %{},
          current_year
        )

      {-score, index, Map.get(item, :id, 0)}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp personalization_available?(profile, insights, semantic_scores) do
    not is_nil(profile) or map_size(semantic_scores || %{}) > 0 or
      Map.get(insights || %{}, :favorite_genres, []) != []
  end

  defp hybrid_score(item, index, count, favorite_slugs, semantic_scores, current_year) do
    semantic = Map.get(semantic_scores, Map.get(item, :id), 0.0) * 55.0
    genre = if genre_match?(item, favorite_slugs), do: 18.0, else: 0.0
    rating = normalized_rating(Map.get(item, :rating)) * 10.0
    recency = recency_score(Map.get(item, :year), current_year) * 7.0
    upstream_order = max(0.0, 1.0 - index / count) * 10.0

    semantic + genre + rating + recency + upstream_order
  end

  defp resolve_profile(:fetch, key), do: Profile.get_user_profile(key)
  defp resolve_profile(profile, _key), do: profile

  defp resolve_insights(:fetch, key), do: Insights.get_user_insights(key)
  defp resolve_insights(insights, _key) when is_map(insights), do: insights
  defp resolve_insights(_insights, _key), do: %{}

  defp genre_match?(item, %MapSet{} = favorite_slugs) do
    item
    |> item_slugs()
    |> Enum.any?(&MapSet.member?(favorite_slugs, &1))
  end

  defp item_slugs(item) do
    case Map.get(item, :genres) do
      %Ecto.Association.NotLoaded{} ->
        []

      nil ->
        []

      genres when is_list(genres) ->
        Enum.flat_map(genres, &extract_genre_slug/1)

      _ ->
        []
    end
  end

  defp extract_genre_slug(%{slug: slug}) when is_binary(slug) and slug != "", do: [slug]
  defp extract_genre_slug(%{"slug" => slug}) when is_binary(slug) and slug != "", do: [slug]
  defp extract_genre_slug(%{name: name}) when is_binary(name), do: Catalog.genre_slugs(name)
  defp extract_genre_slug(%{"name" => name}) when is_binary(name), do: Catalog.genre_slugs(name)
  defp extract_genre_slug(slug) when is_binary(slug) and slug != "", do: [slug]
  defp extract_genre_slug(_), do: []

  defp normalized_rating(%Decimal{} = value), do: normalized_rating(Decimal.to_float(value))
  defp normalized_rating(value) when is_integer(value), do: normalized_rating(value * 1.0)
  defp normalized_rating(value) when is_float(value), do: max(0.0, min(1.0, value / 10.0))

  defp normalized_rating(value) when is_binary(value) do
    case Float.parse(value) do
      {rating, ""} -> normalized_rating(rating)
      _other -> 0.0
    end
  end

  defp normalized_rating(_value), do: 0.0

  defp recency_score(year, current_year) when is_integer(year) and is_integer(current_year) do
    age = max(0, current_year - year)
    max(0.0, 1.0 - age / 15.0)
  end

  defp recency_score(_year, _current_year), do: 0.0
end
