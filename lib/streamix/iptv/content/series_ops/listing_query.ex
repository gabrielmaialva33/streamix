defmodule Streamix.Iptv.Content.SeriesOps.ListingQuery do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Streamix.Helpers

  alias Streamix.Iptv.{Access, AdultFilter, Series}

  @card_fields ~w(id series_id provider_id catalog_item_id name title year cover rating plot tmdb_id gindex_path dub_available inserted_at updated_at)a

  def filtered_provider(provider_id, opts) do
    search = Keyword.get(opts, :search)
    category_id = Keyword.get(opts, :category_id)
    show_adult = Keyword.get(opts, :show_adult, false)

    Series
    |> where(provider_id: ^provider_id)
    |> maybe_where_search(search)
    |> maybe_join_category(category_id)
    |> maybe_exclude_provider_adult(provider_id, show_adult)
  end

  def filtered_visible(user_id, opts) do
    search = Keyword.get(opts, :search)
    show_adult = Keyword.get(opts, :show_adult, false)
    genre_id = Keyword.get(opts, :genre_id)

    Series
    |> Access.visible_to_user(user_id)
    |> where(
      [_series, provider],
      provider.provider_type == :xtream and provider.is_active == true
    )
    |> maybe_where_search(search)
    |> maybe_join_genre(genre_id)
    |> exclude_adult(show_adult)
  end

  def filtered_public(opts) do
    search = Keyword.get(opts, :search)
    category_id = Keyword.get(opts, :category_id)
    show_adult = Keyword.get(opts, :show_adult, false)

    Series
    |> Access.public_providers()
    |> with_provider_filters(opts)
    |> maybe_where_search(search)
    |> maybe_join_category(category_id)
    |> exclude_adult(show_adult)
  end

  def with_provider_filters(query, opts) do
    query
    |> maybe_where_provider(Keyword.get(opts, :provider_id))
    |> maybe_where_provider_type(Keyword.get(opts, :provider_type))
  end

  def public(show_adult) do
    Series
    |> Access.public_providers()
    |> exclude_adult(show_adult)
  end

  def select_card_fields(query) do
    select(query, [series], struct(series, ^@card_fields))
  end

  def variant_page(query, sort, limit, offset) do
    page_ids =
      query
      |> representative_rows()
      |> subquery()
      |> sorted(sort)
      |> limit(^limit)
      |> offset(^offset)
      |> select([representative], representative.id)

    Series
    |> where([series], series.id in subquery(page_ids))
    |> sorted(sort)
  end

  def count_variants(query) do
    query
    |> distinct_representatives(false)
    |> select([series], series.id)
    |> subquery()
    |> select([_representative], count())
  end

  def sorted(query, "rating_desc") do
    order_by(query, [series], [
      fragment("? DESC NULLS LAST", series.rating),
      desc: series.year,
      asc: series.name,
      desc: series.id
    ])
  end

  def sorted(query, "created_desc") do
    order_by(query, [series], desc: series.inserted_at, desc: series.id)
  end

  def sorted(query, "year_desc") do
    order_by(query, [series], [
      fragment("? DESC NULLS LAST", series.year),
      asc: series.name,
      desc: series.id
    ])
  end

  def sorted(query, "name_asc") do
    order_by(query, [series], asc: series.name, desc: series.id)
  end

  def sorted(query, _sort) do
    order_by(query, [series], desc: series.year, asc: series.name, desc: series.id)
  end

  def count(query, true), do: select(query, [series], count(series.id, :distinct))
  def count(query, false), do: select(query, [series], count(series.id))

  def exclude_adult(query, true), do: query
  def exclude_adult(query, _show_adult), do: AdultFilter.exclude_adult_content(query)

  defp maybe_where_search(query, nil), do: query
  defp maybe_where_search(query, ""), do: query

  defp maybe_where_search(query, search) do
    escaped = Helpers.escape_like(search)
    compacted = compact_search(search)

    where(
      query,
      [series],
      ilike(series.name, ^"%#{escaped}%") or
        ilike(series.title, ^"%#{escaped}%") or
        fragment(
          "regexp_replace(lower(coalesce(?, ?)), '[^[:alnum:]]+', '', 'g') LIKE ?",
          series.title,
          series.name,
          ^"%#{compacted}%"
        )
    )
  end

  defp maybe_join_category(query, nil), do: query

  defp maybe_join_category(query, category_id) do
    query
    |> join(:inner, [series], item_category in "item_categories",
      on:
        item_category.catalog_item_id == series.catalog_item_id and
          item_category.category_id == ^category_id
    )
    |> distinct([series], series.id)
  end

  defp maybe_join_genre(query, nil), do: query

  defp maybe_join_genre(query, genre_id) do
    query
    |> join(:inner, [series], series_genre in "series_genres",
      on: series_genre.series_id == series.id and series_genre.genre_id == ^genre_id
    )
    |> distinct([series], series.id)
  end

  defp maybe_exclude_provider_adult(query, _provider_id, true), do: query

  defp maybe_exclude_provider_adult(query, provider_id, _show_adult) do
    AdultFilter.exclude_adult_series(query, provider_id)
  end

  defp compact_search(search) when is_binary(search) do
    search
    |> String.downcase()
    |> String.replace(~r/[^[:alnum:]]+/u, "")
    |> Helpers.escape_like()
  end

  defp maybe_where_provider(query, nil), do: query

  defp maybe_where_provider(query, provider_id),
    do: where(query, [_series, provider], provider.id == ^provider_id)

  defp maybe_where_provider_type(query, nil), do: query

  defp maybe_where_provider_type(query, provider_type),
    do: where(query, [_series, provider], provider.provider_type == ^provider_type)

  defp canonical_key do
    dynamic([series], series.variant_key)
  end

  defp representative_rows(query) do
    query
    |> distinct_representatives(true)
    |> select([series], %{
      id: series.id,
      inserted_at: series.inserted_at,
      name: series.name,
      rating: series.rating,
      year: series.year
    })
  end

  defp distinct_representatives(query, ordered?) do
    key = canonical_key()

    query =
      query
      |> exclude(:order_by)
      |> exclude(:distinct)
      |> distinct(^[key])

    if ordered?, do: order_by(query, ^[asc: key, desc: :id]), else: query
  end
end
