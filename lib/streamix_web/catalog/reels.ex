defmodule StreamixWeb.Catalog.Reels do
  @moduledoc """
  Builds the public short-drama ("Reels") API payloads.

  Cards reuse the series list item shape and add `reel_category`. Paging is
  page-based (`page`/`per_page`) because TV clients render reels as a grid
  with a page cursor; the bounds match `StreamixWeb.Api.V1.Schemas.Reels`.
  """

  alias StreamixWeb.Catalog.Serializer

  @default_per_page 24
  @max_per_page 100
  @max_page 1000
  @max_category_length 100

  @doc "One page of public short dramas, newest first."
  @spec page(map()) :: map()
  def page(params) do
    page = bounded_int(params["page"], 1, @max_page)
    per_page = bounded_int(params["per_page"], @default_per_page, @max_per_page)
    category = category(params["category"])

    reels =
      Streamix.Catalog.list_public_reel_series(
        category: category,
        limit: per_page,
        offset: (page - 1) * per_page
      )

    total = Streamix.Catalog.count_public_reel_series(category: category)
    has_more = page < @max_page and page * per_page < total

    %{
      data: Enum.map(reels, &serialize/1),
      meta: %{
        pagination: %{
          page: page,
          per_page: per_page,
          total: total,
          has_more: has_more,
          next_page: if(has_more, do: page + 1)
        },
        filters: %{category: category}
      }
    }
  end

  @doc "Public reel categories merged across providers, largest first."
  @spec categories() :: map()
  def categories do
    categories = Streamix.Catalog.list_public_reel_categories()

    %{data: categories, meta: %{total: length(categories)}}
  end

  defp serialize(series) do
    series
    |> Serializer.serialize_series()
    |> Map.put(:reel_category, series.reel_category)
  end

  defp category(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      category -> String.slice(category, 0, @max_category_length)
    end
  end

  defp category(_value), do: nil

  defp bounded_int(value, default, maximum) do
    value
    |> parse_int(default)
    |> max(1)
    |> min(maximum)
  end

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default
end
