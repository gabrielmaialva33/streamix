defmodule StreamixWeb.Api.V1.CatalogController do
  @moduledoc """
  Public catalog API for TV app and other clients.

  This controller is intentionally thin: it owns HTTP status/JSON wiring
  while `StreamixWeb.Catalog.Api` composes catalog payloads.
  """

  use StreamixWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import StreamixWeb.Helpers.Params, only: [parse_positive_integer: 1]

  alias StreamixWeb.Api.V1.{Response, Schemas}
  alias StreamixWeb.Catalog.Api

  plug OpenApiSpex.Plug.CastAndValidate,
    render_error: StreamixWeb.Api.V1.OpenApiError,
    replace_params: false

  @json "application/json"
  @unauthorized {"API key authentication failed", @json, Schemas.ref("ApiErrorResponse")}
  @rate_limited {"Rate limit exceeded", @json, Schemas.ref("ApiErrorResponse")}
  @invalid_filter {"Invalid catalog filter", @json, Schemas.ref("ApiErrorResponse")}
  @not_found {"Catalog resource not found", @json, Schemas.ref("ApiErrorResponse")}

  tags ["Catalog"]

  operation :featured,
    operation_id: "catalog.featured",
    summary: "Get the featured title",
    description: "Returns the current public hero title and aggregate public catalog counts.",
    parameters: Schemas.featured_parameters(),
    responses: [
      ok: {"Featured catalog title", @json, Schemas.ref("FeaturedResponse")},
      bad_request: @invalid_filter,
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  operation :providers,
    operation_id: "catalog.providers.list",
    summary: "List public catalog providers",
    description:
      "Returns credential-free provider identity, capabilities and synchronized counts.",
    responses: [
      ok: {"Public catalog providers", @json, Schemas.ref("CatalogProvidersResponse")},
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  operation :movies,
    operation_id: "catalog.movies.list",
    summary: "List canonical public movies",
    description: "Aggregates public/global providers and collapses equivalent provider variants.",
    parameters: Schemas.movies_parameters(),
    responses: [
      ok: {"Paginated movie cards", @json, Schemas.ref("MoviesPageResponse")},
      bad_request: @invalid_filter,
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  operation :series,
    operation_id: "catalog.series.list",
    summary: "List canonical public series",
    description: "Aggregates public/global providers and collapses equivalent provider variants.",
    parameters: Schemas.series_parameters(),
    responses: [
      ok: {"Paginated series cards", @json, Schemas.ref("SeriesPageResponse")},
      bad_request: @invalid_filter,
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  operation :channels,
    operation_id: "catalog.channels.list",
    summary: "List public live channels",
    description:
      "Aggregates active public/global Xtream providers and excludes recently dead channels.",
    parameters: Schemas.channels_parameters(),
    responses: [
      ok: {"Paginated live-channel cards", @json, Schemas.ref("ChannelsPageResponse")},
      bad_request: @invalid_filter,
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  operation :categories,
    operation_id: "catalog.categories.list",
    summary: "List public provider categories",
    description: "Returns provider-scoped non-adult categories with source identity.",
    parameters: Schemas.categories_parameters(),
    responses: [
      ok: {"Catalog categories", @json, Schemas.ref("CatalogCategoriesResponse")},
      bad_request: @invalid_filter,
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  operation :search,
    operation_id: "catalog.search",
    summary: "Search the public catalog",
    parameters: Schemas.search_parameters(),
    responses: [
      ok: {"Ranked search buckets", @json, Schemas.ref("CatalogSearchResponse")},
      bad_request: @invalid_filter,
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  operation :suggest,
    operation_id: "catalog.suggest",
    summary: "Get lightweight typeahead suggestions",
    parameters: Schemas.suggest_parameters(),
    responses: [
      ok: {"Ranked suggestions", @json, Schemas.ref("CatalogSuggestResponse")},
      bad_request: @invalid_filter,
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  operation :home,
    operation_id: "catalog.home",
    summary: "Get the complete home catalog payload",
    description: "Builds featured, trending, recent and top-rated sections concurrently.",
    parameters: Schemas.home_parameters(),
    responses: [
      ok: {"Home catalog sections", @json, Schemas.ref("CatalogHomeResponse")},
      bad_request: @invalid_filter,
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  operation :trending,
    operation_id: "catalog.trending",
    summary: "List trending titles",
    parameters: Schemas.shelf_parameters(),
    responses: [
      ok: {"Catalog shelf", @json, Schemas.ref("CatalogShelfResponse")},
      bad_request: @invalid_filter,
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  operation :recent,
    operation_id: "catalog.recent",
    summary: "List recently added titles",
    parameters: Schemas.shelf_parameters(),
    responses: [
      ok: {"Catalog shelf", @json, Schemas.ref("CatalogShelfResponse")},
      bad_request: @invalid_filter,
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  operation :top_rated,
    operation_id: "catalog.topRated",
    summary: "List top-rated titles",
    parameters: Schemas.shelf_parameters(),
    responses: [
      ok: {"Catalog shelf", @json, Schemas.ref("CatalogShelfResponse")},
      bad_request: @invalid_filter,
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  operation :show_movie,
    operation_id: "catalog.movies.get",
    summary: "Get public movie details",
    parameters: Schemas.id_parameter("Movie"),
    responses: [
      ok: {"Movie details", @json, Schemas.ref("MovieDetailResponse")},
      bad_request: @invalid_filter,
      not_found: @not_found,
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  operation :show_series,
    operation_id: "catalog.series.get",
    summary: "Get public series details",
    parameters: Schemas.id_parameter("Series"),
    responses: [
      ok: {"Series details", @json, Schemas.ref("SeriesDetailResponse")},
      bad_request: @invalid_filter,
      not_found: @not_found,
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  operation :show_episode,
    operation_id: "catalog.episodes.get",
    summary: "Get public episode details",
    parameters: Schemas.id_parameter("Episode"),
    responses: [
      ok: {"Episode details", @json, Schemas.ref("EpisodeDetailResponse")},
      bad_request: @invalid_filter,
      not_found: @not_found,
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  operation :show_channel,
    operation_id: "catalog.channels.get",
    summary: "Get public channel details",
    parameters: Schemas.id_parameter("Channel"),
    responses: [
      ok: {"Channel details", @json, Schemas.ref("ChannelDetailResponse")},
      bad_request: @invalid_filter,
      not_found: @not_found,
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  operation :movie_stream,
    operation_id: "catalog.movies.stream",
    summary: "Create a signed movie playback URL",
    parameters: Schemas.id_parameter("Movie"),
    responses: [
      ok: {"Signed playback URL", @json, Schemas.ref("StreamResponse")},
      bad_request: @invalid_filter,
      not_found: @not_found,
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  operation :episode_stream,
    operation_id: "catalog.episodes.stream",
    summary: "Create a signed episode playback URL",
    parameters: Schemas.id_parameter("Episode"),
    responses: [
      ok: {"Signed playback URL", @json, Schemas.ref("StreamResponse")},
      bad_request: @invalid_filter,
      not_found: @not_found,
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  operation :channel_stream,
    operation_id: "catalog.channels.stream",
    summary: "Create a signed channel playback URL",
    parameters: Schemas.id_parameter("Channel"),
    responses: [
      ok: {"Signed playback URL", @json, Schemas.ref("StreamResponse")},
      bad_request: @invalid_filter,
      not_found: @not_found,
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  def featured(conn, params), do: json(conn, Api.featured(params))
  def providers(conn, _params), do: json(conn, Api.providers())
  def movies(conn, params), do: json(conn, Api.movies(params))
  def series(conn, params), do: json(conn, Api.series(params))
  def channels(conn, params), do: json(conn, Api.channels(params))
  def categories(conn, params), do: json(conn, Api.categories(params))
  def search(conn, params), do: json(conn, Api.search(params))
  def suggest(conn, params), do: json(conn, Api.suggest(params))
  def home(conn, params), do: json(conn, Api.home(params))
  def trending(conn, params), do: json(conn, Api.trending(params))
  def recent(conn, params), do: json(conn, Api.recent(params))
  def top_rated(conn, params), do: json(conn, Api.top_rated(params))

  def show_movie(conn, %{"id" => id}) do
    render_id_result(conn, id, &Api.movie_detail/1, "Movie not found")
  end

  def show_series(conn, %{"id" => id}) do
    render_id_result(conn, id, &Api.series_detail/1, "Series not found")
  end

  def show_episode(conn, %{"id" => id}) do
    render_id_result(conn, id, &Api.episode_detail/1, "Episode not found")
  end

  def show_channel(conn, %{"id" => id}) do
    render_id_result(conn, id, &Api.channel_detail/1, "Channel not found")
  end

  def movie_stream(conn, %{"id" => id}) do
    render_id_result(conn, id, &Api.movie_stream/1, "Movie not found")
  end

  def episode_stream(conn, %{"id" => id}) do
    render_id_result(conn, id, &Api.episode_stream/1, "Episode not found")
  end

  def channel_stream(conn, %{"id" => id}) do
    render_id_result(conn, id, &Api.channel_stream/1, "Channel not found")
  end

  defp render_result(conn, {:ok, payload}, _not_found_message), do: json(conn, payload)

  defp render_result(conn, {:error, :not_found}, not_found_message) do
    Response.error(conn, :not_found, "content_not_found", not_found_message)
  end

  defp render_id_result(conn, raw_id, fun, not_found_message) do
    case parse_positive_integer(raw_id) do
      {:ok, id} -> render_result(conn, fun.(id), not_found_message)
      :error -> render_result(conn, {:error, :not_found}, not_found_message)
    end
  end
end
