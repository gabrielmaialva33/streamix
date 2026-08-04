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

  import StreamixWeb.Helpers.Params,
    only: [bounded_integer: 4, parse_positive_integer: 1]

  alias Streamix.AI
  alias Streamix.Billing
  alias Streamix.Cache
  alias Streamix.Helpers
  alias Streamix.Iptv
  alias StreamixWeb.Api.V1.Response
  alias StreamixWeb.Helpers.ImageProxy

  # Pipeline `:api_v1` never sets `current_scope` (that's a browser-only
  # concern), so the previous `require_authenticated_user` always
  # 401'd. BearerAuth resolves the user from the session token the TV
  # app is already sending and assigns it to `:current_user`.
  plug StreamixWeb.Plugs.BearerAuth
  plug :require_ai_recommendations

  @doc """
  GET /api/v1/recommendations
  Get personalized "For You" recommendations based on watch history.
  """
  def index(conn, params) do
    case parse_content_type(Map.get(params, "type", "movies")) do
      {:ok, collection} -> personalized_recommendations(conn, params, collection)
      :invalid_content_type -> invalid_content_type(conn)
    end
  end

  defp personalized_recommendations(conn, params, collection) do
    user = conn.assigns.current_user
    limit = parse_int(params["limit"], 20)

    case AI.get_recommendations(user.id,
           type: collection,
           limit: candidate_limit(limit),
           exclude_watched: true
         ) do
      recommendations when is_list(recommendations) ->
        render_recommendations(conn, recommendations, collection, user, limit)

      {:ok, recommendations} ->
        render_recommendations(conn, recommendations, collection, user, limit)

      {:error, reason} ->
        Response.internal_error(
          conn,
          :service_unavailable,
          "recommendations_unavailable",
          "Recommendations unavailable",
          reason
        )
    end
  end

  defp render_recommendations(conn, recommendations, collection, user, limit) do
    enriched = enrich_results(recommendations, collection, user) |> Enum.take(limit)

    json(conn, %{
      recommendations: enriched,
      type: collection,
      personalized: true
    })
  end

  defp require_ai_recommendations(conn, _opts) do
    if Billing.entitled?(conn.assigns.current_user, :ai_recommendations) do
      conn
    else
      conn
      |> Response.error(
        :payment_required,
        "ai_recommendations_required",
        "AI recommendations require a plan with advanced AI enabled",
        upgrade_url: ~p"/plans?upgrade=ai"
      )
      |> halt()
    end
  end

  @doc """
  GET /api/v1/recommendations/similar/:id
  Get "Because you watched X" recommendations.
  """
  def similar(conn, %{"id" => id} = params) do
    with {:ok, content_id} <- parse_positive_integer(id),
         {:ok, collection} <- parse_content_type(Map.get(params, "type", "movies")) do
      user = conn.assigns.current_user
      limit = parse_int(params["limit"], 10)
      similar_for_source(conn, user, collection, content_id, limit)
    else
      :error -> invalid_id(conn)
      :invalid_content_type -> invalid_content_type(conn)
    end
  end

  defp similar_for_source(conn, user, collection, content_id, limit) do
    if visible_source?(user, collection, content_id) do
      fetch_similar(conn, user, collection, content_id, limit)
    else
      Response.error(conn, :not_found, "content_not_found", "Content not found")
    end
  end

  defp fetch_similar(conn, user, collection, content_id, limit) do
    case AI.get_similar_to(content_id, collection, limit: candidate_limit(limit)) do
      {:ok, results} ->
        enriched = enrich_results(results, collection, user) |> Enum.take(limit)

        json(conn, %{
          similar: enriched,
          source_id: content_id,
          type: collection
        })

      {:error, :not_found} ->
        Response.error(
          conn,
          :not_found,
          "content_not_indexed",
          "Content not indexed"
        )

      {:error, reason} ->
        Response.internal_error(
          conn,
          :service_unavailable,
          "similar_search_failed",
          "Similar search failed",
          reason
        )
    end
  end

  @doc """
  GET /api/v1/recommendations/channels
  Get recommended live channels based on watch history.
  """
  def channels(conn, params) do
    user = conn.assigns.current_user
    limit = parse_int(params["limit"], 10)

    {:ok, channels} =
      AI.get_channel_recommendations(user.id,
        limit: limit,
        show_adult: user.show_adult_content
      )

    serialized = Enum.map(channels, &serialize_channel/1)
    json(conn, %{channels: serialized, personalized: true})
  end

  @doc """
  GET /api/v1/recommendations/insights
  Get user viewing insights and stats.
  """
  def insights(conn, _params) do
    user_id = conn.assigns.current_user.id

    insights = AI.get_user_insights(user_id)

    json(conn, %{insights: insights})
  end

  @doc """
  POST /api/v1/recommendations/refresh
  Force refresh user profile (recalculate from watch history).
  """
  def refresh(conn, _params) do
    user_id = conn.assigns.current_user.id
    Cache.invalidate_personalization(user_id)

    case AI.compute_user_profile(user_id) do
      {:ok, _vector} ->
        json(conn, %{status: "refreshed"})

      {:error, :no_history} ->
        json(conn, %{status: "no_history", message: "Watch some content first"})

      {:error, reason} ->
        Response.internal_error(
          conn,
          :service_unavailable,
          "profile_refresh_failed",
          "Refresh failed",
          reason
        )
    end
  end

  # Private functions

  defp enrich_results(results, "movies", user), do: enrich_movie_results(results, user)
  defp enrich_results(results, "series", user), do: enrich_series_results(results, user)

  defp enrich_movie_results(results, user) do
    results = normalize_result_ids(results)
    ids = Enum.map(results, & &1.id)

    movies =
      Iptv.list_visible_movies_by_ids(user.id, ids, show_adult: user.show_adult_content)

    movies_map = Map.new(movies, &{&1.id, &1})

    Enum.flat_map(results, fn result ->
      case Map.fetch(movies_map, result.id) do
        {:ok, movie} -> [merge_movie(result, movie)]
        :error -> []
      end
    end)
  end

  defp enrich_series_results(results, user) do
    results = normalize_result_ids(results)
    ids = Enum.map(results, & &1.id)

    series =
      Iptv.list_visible_series_by_ids(user.id, ids, show_adult: user.show_adult_content)

    series_map = Map.new(series, &{&1.id, &1})

    Enum.flat_map(results, fn result ->
      case Map.fetch(series_map, result.id) do
        {:ok, series} -> [merge_series(result, series)]
        :error -> []
      end
    end)
  end

  defp visible_source?(user, "movies", id) do
    Iptv.list_visible_movies_by_ids(user.id, [id], show_adult: user.show_adult_content) != []
  end

  defp visible_source?(user, "series", id) do
    Iptv.list_visible_series_by_ids(user.id, [id], show_adult: user.show_adult_content) != []
  end

  defp parse_content_type(type) when type in ["movies", "series"], do: {:ok, type}
  defp parse_content_type(_type), do: :invalid_content_type

  defp invalid_content_type(conn) do
    Response.error(conn, :bad_request, "invalid_content_type", "Invalid content type")
  end

  defp candidate_limit(limit), do: min(limit * 4, 200)

  defp normalize_result_ids(results) do
    Enum.flat_map(results, fn
      %{id: id} = result ->
        case parse_positive_integer(id) do
          {:ok, normalized_id} -> [Map.put(result, :id, normalized_id)]
          :error -> []
        end

      _result ->
        []
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
      backdrop: Iptv.backdrop_urls(movie) |> List.first() |> ImageProxy.hero(),
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
      backdrop: Iptv.backdrop_urls(series) |> List.first() |> ImageProxy.hero(),
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

  defp parse_int(value, default), do: bounded_integer(value, default, 1, 50)

  defp invalid_id(conn) do
    Response.error(conn, :bad_request, "invalid_id", "Invalid content id")
  end
end
