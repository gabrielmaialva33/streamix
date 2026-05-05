defmodule StreamixWeb.Catalog.Params do
  @moduledoc """
  Normalizes Catalog API query parameters.
  """

  @allowed_sorts ~w(rating_desc created_desc year_desc name_asc)

  def movies_opts(params) do
    [
      limit: capped_int(params["limit"], 20, 100),
      offset: parse_int(params["offset"], 0),
      category_id: parse_int(params["category_id"], nil),
      search: params["search"],
      sort: normalize_sort(params["sort"])
    ]
  end

  def series_opts(params), do: movies_opts(params)

  def channels_opts(params) do
    requested_limit = params["limit"] || params["per_page"]

    [
      limit: capped_int(requested_limit, 30, 100),
      offset: parse_int(params["offset"], 0),
      category_id: parse_int(params["category_id"], nil),
      search: params["search"]
    ]
  end

  def search_limit(params), do: capped_int(params["limit"], 10, 20)
  def suggest_limit(params), do: capped_int(params["limit"], 10, 20)
  def home_limit(params), do: capped_int(params["limit"], 20, 50)
  def shelf_limit(params), do: capped_int(params["limit"], 20, 50)

  def search_query(query, max_bytes) when is_binary(query), do: String.slice(query, 0, max_bytes)
  def search_query(_query, _max_bytes), do: ""

  def content_type("series"), do: "series"
  def content_type(_), do: "movie"

  def category_type("movie"), do: "vod"
  def category_type("movies"), do: "vod"
  def category_type(nil), do: "vod"
  def category_type(other), do: other

  defp capped_int(value, default, max), do: min(parse_int(value, default), max)

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

  defp normalize_sort(value) when value in @allowed_sorts, do: value
  defp normalize_sort(_), do: nil
end
