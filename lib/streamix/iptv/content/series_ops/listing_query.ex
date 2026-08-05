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

  def public(show_adult) do
    Series
    |> Access.public_providers()
    |> exclude_adult(show_adult)
  end

  def select_card_fields(query) do
    select(query, [series], struct(series, ^@card_fields))
  end

  def dedupe_variants(query) do
    key = canonical_key()

    representative_ids =
      query
      |> exclude(:order_by)
      |> exclude(:distinct)
      |> distinct(^[key])
      |> order_by(^[asc: key, desc: :id])
      |> select([series], series.id)

    from(series in Series, where: series.id in subquery(representative_ids))
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

  defp canonical_key do
    dynamic(
      [series],
      fragment(
        """
        CASE
          WHEN nullif(?, '') IS NOT NULL THEN 'tmdb:' || ?
          ELSE 'title:' ||
            lower(
              btrim(
                regexp_replace(
                  regexp_replace(
                    regexp_replace(
                      regexp_replace(
                        coalesce(?, ?),
                        '\\s*\\[[^\\]]+\\]',
                        ' ',
                        'g'
                      ),
                      '\\m(4k|2160p|1080p|720p|hdr10|hdr|dublado|legendado|dual audio|dual-audio|dub|leg|x264|x265|h264|h265|hevc|web-dl|webrip|bluray|blu-ray)\\M',
                      ' ',
                      'gi'
                    ),
                    '[[:punct:]]+',
                    ' ',
                    'g'
                  ),
                  '\\s+',
                  ' ',
                  'g'
                )
              )
            ) || ':' || coalesce(?::text, '')
        END
        """,
        series.tmdb_id,
        series.tmdb_id,
        series.title,
        series.name,
        series.year
      )
    )
  end
end
