defmodule StreamixWeb.Api.V1.RecommendationsController do
  @moduledoc """
  Personalized recommendations API controller.

  Provides AI-powered personalized content recommendations
  based on user watch history and taste profile.

  ## Endpoints

  - GET /api/v1/recommendations - Get personalized "For You" recommendations
  - GET /api/v1/recommendations/similar/:id - "Because you watched X"
  - GET /api/v1/recommendations/channels - Recommended live channels
  - GET /api/v1/recommendations/insights - User viewing insights

  ## Authentication

  Requires authenticated user. Uses watch history to compute taste profile.
  """
  use StreamixWeb, :controller

  alias Streamix.AI.UserAnalytics
  alias Streamix.Helpers
  alias Streamix.Iptv
  alias Streamix.Iptv.{Movie, Series}
  alias StreamixWeb.Helpers.ImageProxy

  # Pipeline `:api_v1` never sets `current_scope` (that's a browser-only
  # concern), so the previous `require_authenticated_user` always
  # 401'd. BearerAuth resolves the user from the session token the TV
  # app is already sending and assigns it to `:current_user`.
  plug StreamixWeb.Plugs.BearerAuth

  @doc """
  GET /api/v1/recommendations
  Get personalized "For You" recommendations based on watch history.
  """
  def index(conn, params) do
    user_id = conn.assigns.current_user.id
    collection = Map.get(params, "type", "movies")
    limit = parse_int(params["limit"], 20)

    case UserAnalytics.get_recommendations(user_id, type: collection, limit: limit) do
      recommendations when is_list(recommendations) ->
        enriched = enrich_results(recommendations, collection)

        json(conn, %{
          recommendations: enriched,
          type: collection,
          personalized: true
        })

      {:ok, recommendations} ->
        enriched = enrich_results(recommendations, collection)

        json(conn, %{
          recommendations: enriched,
          type: collection,
          personalized: true
        })

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Recommendations unavailable", reason: inspect(reason)})
    end
  end

  @doc """
  GET /api/v1/recommendations/similar/:id
  Get "Because you watched X" recommendations.
  """
  def similar(conn, %{"id" => id} = params) do
    content_id = String.to_integer(id)
    collection = Map.get(params, "type", "movies")
    limit = parse_int(params["limit"], 10)

    case UserAnalytics.get_similar_to(content_id, collection, limit: limit) do
      {:ok, results} ->
        enriched = enrich_results(results, collection)

        json(conn, %{
          similar: enriched,
          source_id: content_id,
          type: collection
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Content not indexed"})

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Similar search failed", reason: inspect(reason)})
    end
  end

  @doc """
  GET /api/v1/recommendations/channels
  Get recommended live channels based on watch history.
  """
  def channels(conn, params) do
    user_id = conn.assigns.current_user.id
    limit = parse_int(params["limit"], 10)

    {:ok, channels} = UserAnalytics.get_channel_recommendations(user_id, limit: limit)
    serialized = Enum.map(channels, &serialize_channel/1)
    json(conn, %{channels: serialized, personalized: true})
  end

  @doc """
  GET /api/v1/recommendations/insights
  Get user viewing insights and stats.
  """
  def insights(conn, _params) do
    user_id = conn.assigns.current_user.id

    insights = UserAnalytics.get_user_insights(user_id)

    json(conn, %{insights: insights})
  end

  @doc """
  POST /api/v1/recommendations/refresh
  Force refresh user profile (recalculate from watch history).
  """
  def refresh(conn, _params) do
    user_id = conn.assigns.current_user.id

    case UserAnalytics.compute_user_profile(user_id) do
      {:ok, _vector} ->
        json(conn, %{status: "refreshed"})

      {:error, :no_history} ->
        json(conn, %{status: "no_history", message: "Watch some content first"})

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Refresh failed", reason: inspect(reason)})
    end
  end

  # Private functions

  defp enrich_results(results, "movies"), do: enrich_movie_results(results)
  defp enrich_results(results, "series"), do: enrich_series_results(results)
  defp enrich_results(results, _), do: results

  defp enrich_movie_results(results) do
    ids = Enum.map(results, & &1.id)
    movies = Iptv.get_movies_by_ids(ids)
    movies_map = Map.new(movies, &{&1.id, &1})

    Enum.map(results, fn result ->
      case Map.get(movies_map, result.id) do
        nil -> result
        movie -> merge_movie(result, movie)
      end
    end)
  end

  defp enrich_series_results(results) do
    ids = Enum.map(results, & &1.id)
    series = Iptv.get_series_by_ids(ids)
    series_map = Map.new(series, &{&1.id, &1})

    Enum.map(results, fn result ->
      case Map.get(series_map, result.id) do
        nil -> result
        s -> merge_series(result, s)
      end
    end)
  end

  defp merge_movie(result, movie) do
    %{
      id: movie.id,
      name: movie.name,
      title: movie.title,
      year: movie.year,
      rating: movie.rating && Decimal.to_float(movie.rating),
      genre: Helpers.genre_names(movie.genres),
      poster: ImageProxy.card(movie.stream_icon),
      backdrop: Movie.backdrop_urls(movie) |> List.first() |> ImageProxy.hero(),
      plot: movie.plot,
      score: Map.get(result, :score)
    }
  end

  defp merge_series(result, series) do
    %{
      id: series.id,
      name: series.name,
      title: series.title,
      year: series.year,
      rating: series.rating && Decimal.to_float(series.rating),
      genre: Helpers.genre_names(series.genres),
      poster: ImageProxy.card(series.cover),
      backdrop: Series.backdrop_urls(series) |> List.first() |> ImageProxy.hero(),
      plot: series.plot,
      score: Map.get(result, :score)
    }
  end

  defp serialize_channel(channel) do
    %{
      id: channel.id,
      name: channel.name,
      category: channel.category,
      logo: channel.stream_icon,
      provider_id: channel.provider_id
    }
  end

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_, default), do: default
end
