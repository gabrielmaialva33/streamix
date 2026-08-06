defmodule StreamixWeb.Catalog.Params do
  @moduledoc """
  Normalizes Catalog API query parameters.
  """

  @allowed_sorts ~w(rating_desc created_desc year_desc name_asc)
  @provider_types %{"gindex" => :gindex, "torrent" => :torrent, "xtream" => :xtream}

  alias StreamixWeb.Catalog.Pagination

  def movies_opts(params) do
    [
      limit: capped_int(params["limit"], 20, 100),
      offset: bounded_int(params["offset"], 0, 0, Pagination.max_offset()),
      category_id: positive_int(params["category_id"]),
      search: params["search"],
      sort: normalize_sort(params["sort"]),
      provider_id: positive_int(params["provider_id"]),
      provider_type: normalize_provider_type(params["provider_type"])
    ]
  end

  def series_opts(params), do: movies_opts(params)

  def channels_opts(params) do
    requested_limit = params["limit"] || params["per_page"]

    [
      limit: capped_int(requested_limit, 30, 100),
      offset: bounded_int(params["offset"], 0, 0, Pagination.max_offset()),
      category_id: positive_int(params["category_id"]),
      search: params["search"],
      provider_id: positive_int(params["provider_id"]),
      provider_type: normalize_provider_type(params["provider_type"])
    ]
  end

  def categories_opts(params) do
    [type: category_type(params["type"])] ++ provider_opts(params)
  end

  @doc "Normalizes the public-provider scope shared by catalog resources and search."
  @spec provider_opts(map()) :: keyword()
  def provider_opts(params) when is_map(params) do
    [
      provider_id: positive_int(params["provider_id"]),
      provider_type: normalize_provider_type(params["provider_type"])
    ]
  end

  def search_limit(params), do: capped_int(params["limit"], 10, 20)
  def suggest_limit(params), do: capped_int(params["limit"], 10, 20)
  def home_limit(params), do: capped_int(params["limit"], 20, 50)
  def shelf_limit(params), do: capped_int(params["limit"], 20, 50)

  def search_query(query, max_length) when is_binary(query) do
    query
    |> String.trim()
    |> String.slice(0, max_length)
  end

  def search_query(_query, _max_length), do: ""

  def content_type("series"), do: "series"
  def content_type(_), do: "movie"

  def category_type("movie"), do: "vod"
  def category_type("movies"), do: "vod"
  def category_type(nil), do: "vod"
  def category_type(other), do: other

  defp capped_int(value, default, maximum), do: bounded_int(value, default, 1, maximum)

  defp bounded_int(value, default, minimum, maximum) do
    value
    |> parse_int(default)
    |> max(minimum)
    |> min(maximum)
  end

  defp positive_int(value) do
    case parse_int(value, nil) do
      integer when is_integer(integer) and integer > 0 -> integer
      _ -> nil
    end
  end

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_, default), do: default

  defp normalize_sort(value) when value in @allowed_sorts, do: value
  defp normalize_sort(_), do: nil

  defp normalize_provider_type(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> then(&Map.get(@provider_types, &1))
  end

  defp normalize_provider_type(_value), do: nil
end
