defmodule StreamixWeb.Api.V1.ReelsController do
  @moduledoc """
  Short dramas ("Reels") for the TV app.

  Providers ship vertical short dramas as ordinary series tagged with
  `[Reels] ...` categories. These endpoints merge those categories across
  public providers; each card opens with the regular series endpoints.
  """

  use StreamixWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias StreamixWeb.Api.V1.Schemas
  alias StreamixWeb.Catalog.Reels

  plug OpenApiSpex.Plug.CastAndValidate,
    render_error: StreamixWeb.Api.V1.OpenApiError,
    replace_params: false

  @json "application/json"
  @unauthorized {"API key authentication failed", @json, Schemas.ref("ApiErrorResponse")}
  @rate_limited {"Rate limit exceeded", @json, Schemas.ref("ApiErrorResponse")}
  @invalid_filter {"Invalid catalog filter", @json, Schemas.ref("ApiErrorResponse")}

  tags ["Catalog"]

  operation :index,
    operation_id: "catalog.reels.list",
    summary: "List short dramas",
    description:
      "Lists vertical short-drama series from public/global providers, newest first. " <>
        "An unknown category returns an empty page.",
    parameters: Schemas.reels_parameters(),
    responses: [
      ok: {"Paginated short-drama cards", @json, Schemas.ref("ReelsPageResponse")},
      bad_request: @invalid_filter,
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  operation :categories,
    operation_id: "catalog.reels.categories",
    summary: "List short-drama categories",
    description:
      "Returns the providers' reel categories merged by display name, with the number " <>
        "of short dramas in each.",
    responses: [
      ok: {"Short-drama categories", @json, Schemas.ref("ReelCategoriesResponse")},
      unauthorized: @unauthorized,
      too_many_requests: @rate_limited
    ]

  def index(conn, params), do: json(conn, Reels.page(params))
  def categories(conn, _params), do: json(conn, Reels.categories())
end
