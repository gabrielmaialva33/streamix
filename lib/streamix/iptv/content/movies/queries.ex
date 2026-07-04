defmodule Streamix.Iptv.Content.Movies.Queries do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Streamix.Helpers

  alias Streamix.Iptv.{
    Access,
    AdultFilter,
    Movie,
    RankedSearch
  }

  @card_fields ~w(id stream_id provider_id catalog_item_id name title year stream_icon rating plot duration_secs inserted_at updated_at)a

  def filtered_provider(provider_id, opts) do
    search = Keyword.get(opts, :search)
    category_id = Keyword.get(opts, :category_id)
    year = Keyword.get(opts, :year)
    show_adult = Keyword.get(opts, :show_adult, false)

    Movie
    |> where(provider_id: ^provider_id)
    |> maybe_where_search(search)
    |> maybe_join_category(category_id)
    |> maybe_where_year(year)
    |> maybe_exclude_adult(provider_id, show_adult)
  end

  def sorted(query, "rating_desc"),
    do: order_by(query, [m], [fragment("? DESC NULLS LAST", m.rating), desc: m.year, asc: m.name])

  def sorted(query, "created_desc"),
    do: order_by(query, [m], desc: m.inserted_at)

  def sorted(query, "year_desc"),
    do: order_by(query, [m], [fragment("? DESC NULLS LAST", m.year), asc: m.name])

  def sorted(query, "name_asc"), do: order_by(query, [m], asc: m.name)
  def sorted(query, _sort), do: order_by(query, [m], desc: m.year, asc: m.name)

  def dedupe_variants(query) do
    key = canonical_key()

    representative_ids =
      query
      |> exclude(:order_by)
      |> exclude(:distinct)
      |> distinct(^[key])
      |> order_by(^[asc: key, desc: :id])
      |> select([m], m.id)

    from(m in Movie, where: m.id in subquery(representative_ids))
  end

  def select_card_fields(query) do
    select(query, [m], struct(m, ^@card_fields))
  end

  def count_provider(provider_id, opts) do
    has_category = Keyword.get(opts, :category_id) != nil

    provider_id
    |> filtered_provider(opts)
    |> exclude(:distinct)
    |> count_query(has_category)
  end

  def public_list(limit) do
    Movie
    |> Access.public_providers()
    |> where([m, _p], not is_nil(m.stream_icon))
    |> order_by([m], desc: m.rating, desc: m.year, asc: m.name)
    |> limit(^limit)
  end

  def visible_search(user_id, query, limit) do
    escaped = Helpers.escape_like(query)

    Movie
    |> Access.visible_to_user(user_id)
    |> where([m, _p], ilike(m.name, ^"%#{escaped}%") or ilike(m.title, ^"%#{escaped}%"))
    |> order_by([m], desc: m.rating, asc: m.name)
    |> limit(^limit)
  end

  def public_search(query, limit) do
    Movie
    |> Access.public_providers()
    |> RankedSearch.build([:name, :title], query, limit: limit)
  end

  defp maybe_where_search(query, nil), do: query
  defp maybe_where_search(query, ""), do: query

  defp maybe_where_search(query, search) do
    escaped = Helpers.escape_like(search)
    where(query, [m], ilike(m.name, ^"%#{escaped}%"))
  end

  defp maybe_join_category(query, nil), do: query

  defp maybe_join_category(query, category_id) do
    query
    |> join(:inner, [m], ic in "item_categories",
      on: ic.catalog_item_id == m.catalog_item_id and ic.category_id == ^category_id
    )
    |> distinct([m], m.id)
  end

  defp maybe_where_year(query, nil), do: query
  defp maybe_where_year(query, year), do: where(query, year: ^year)

  defp maybe_exclude_adult(query, _provider_id, true), do: query

  defp maybe_exclude_adult(query, provider_id, _show_adult),
    do: AdultFilter.exclude_adult_movies(query, provider_id)

  def canonical_key do
    dynamic(
      [m],
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
        m.tmdb_id,
        m.tmdb_id,
        m.title,
        m.name,
        m.year
      )
    )
  end

  def normalized_title do
    dynamic(
      [m],
      fragment(
        """
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
        )
        """,
        m.title,
        m.name
      )
    )
  end

  defp count_query(query, true), do: select(query, [m], count(m.id, :distinct))
  defp count_query(query, false), do: select(query, [m], count(m.id))
end
