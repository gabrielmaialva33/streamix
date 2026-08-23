defmodule Streamix.AI.UserAnalytics.Context do
  @moduledoc """
  Shared personalization inputs for one request lifecycle.

  Home and recommendation surfaces ask for the user profile and viewing
  insights together, then pass this immutable context to every shelf. This
  prevents sibling tasks from independently resolving the same cached profile
  and keeps optional AI latency out of unrelated catalog work.
  """

  alias Streamix.AI.UserAnalytics.{Insights, Profile, Recommendations}

  @recommendation_limit 48

  @type recommendation :: map()
  @type score_map :: %{optional(pos_integer()) => float()}
  @type t :: %{
          profile: [number()] | nil,
          insights: map(),
          movie_recommendations: [recommendation()],
          series_recommendations: [recommendation()],
          movie_scores: score_map(),
          series_scores: score_map()
        }

  @doc "Loads cached profile, insights, and bounded semantic rankings once for a user."
  @spec load(pos_integer()) :: t()
  def load(user_id) when is_integer(user_id) and user_id > 0 do
    profile = Profile.get_user_profile(user_id)
    insights = Insights.get_user_insights(user_id)

    rankings =
      [movies: "movies", series: "series"]
      |> Task.async_stream(
        fn {key, collection} ->
          recommendations = semantic_recommendations(user_id, collection, profile)
          {key, recommendations}
        end,
        ordered: true,
        max_concurrency: 2,
        timeout: 8_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{movies: [], series: []}, fn
        {:ok, {key, recommendations}}, acc -> Map.put(acc, key, recommendations)
        {:exit, _reason}, acc -> acc
      end)

    %{
      profile: profile,
      insights: insights,
      movie_recommendations: rankings.movies,
      series_recommendations: rankings.series,
      movie_scores: score_map(rankings.movies),
      series_scores: score_map(rankings.series)
    }
  end

  defp semantic_recommendations(_user_id, _collection, nil), do: []

  defp semantic_recommendations(user_id, collection, profile) do
    user_id
    |> Recommendations.get_recommendations(
      type: collection,
      limit: @recommendation_limit,
      profile: profile
    )
    |> normalize_recommendations()
  end

  defp normalize_recommendations(recommendations) when is_list(recommendations),
    do: recommendations

  defp normalize_recommendations({:ok, recommendations}) when is_list(recommendations),
    do: recommendations

  defp normalize_recommendations(_result), do: []

  defp score_map(recommendations) do
    recommendations
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {recommendation, index}, acc ->
      with {:ok, id} <- recommendation_id(recommendation),
           score <- recommendation_score(recommendation, index, length(recommendations)) do
        Map.put_new(acc, id, score)
      else
        _ -> acc
      end
    end)
  end

  defp recommendation_id(%{id: id}), do: normalize_id(id)
  defp recommendation_id(%{"id" => id}), do: normalize_id(id)
  defp recommendation_id(_recommendation), do: :error

  defp normalize_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _other -> :error
    end
  end

  defp normalize_id(_id), do: :error

  defp recommendation_score(recommendation, index, count) do
    explicit = Map.get(recommendation, :score) || Map.get(recommendation, "score")

    case numeric_score(explicit) do
      nil -> max(0.0, 1.0 - index / max(count, 1))
      score -> max(0.0, min(1.0, score))
    end
  end

  defp numeric_score(%Decimal{} = value), do: Decimal.to_float(value)
  defp numeric_score(value) when is_integer(value), do: value * 1.0
  defp numeric_score(value) when is_float(value), do: value

  defp numeric_score(value) when is_binary(value) do
    case Float.parse(value) do
      {score, ""} -> score
      _other -> nil
    end
  end

  defp numeric_score(_value), do: nil
end
