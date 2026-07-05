defmodule Streamix.Iptv.Content.SeriesOps.Queries do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Streamix.Helpers

  alias Streamix.Iptv.{
    Access,
    AdultFilter,
    Episode,
    Provider,
    RankedSearch,
    Season,
    Series
  }

  alias Streamix.Repo

  @summary_preloads [:genres]
  @search_result_preloads [:assets, :genres]
  @detail_preloads [:assets, :genres, credits: :person]
  @variant_terms ~r/\b(4k|2160p|1080p|720p|hdr10|hdr|dublado|legendado|dual audio|dual-audio|dub|leg|x264|x265|h264|h265|hevc|web-dl|webrip|bluray|blu-ray)\b/iu
  @card_fields ~w(id series_id provider_id catalog_item_id name title year cover rating plot tmdb_id gindex_path dub_available inserted_at updated_at)a
  @visible_dedupe_min_window 120

  @spec list(integer(), keyword()) :: [Series.t()]
  def list(provider_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    sort = Keyword.get(opts, :sort)
    dedupe? = Keyword.get(opts, :dedupe, false)

    provider_id
    |> build_filtered_query(opts)
    |> maybe_dedupe_variants(dedupe?)
    |> apply_series_sort(sort)
    |> limit(^limit)
    |> offset(^offset)
    |> select_card_fields()
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  @spec list_visible(integer(), keyword()) :: [Series.t()]
  def list_visible(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    sort = Keyword.get(opts, :sort)
    dedupe? = Keyword.get(opts, :dedupe, true)

    if dedupe? do
      list_visible_deduped(user_id, opts, limit, offset, sort)
    else
      list_visible_candidates(user_id, opts, sort, limit, offset)
    end
  end

  defp list_visible_deduped(user_id, opts, limit, offset, sort) do
    target_count = offset + limit
    batch_limit = max(limit * 4, @visible_dedupe_min_window)

    user_id
    |> collect_visible_cards(opts, sort, batch_limit, 0, target_count, %{})
    |> sort_visible_cards(sort)
    |> Enum.slice(offset, limit)
  end

  defp collect_visible_cards(
         user_id,
         opts,
         sort,
         batch_limit,
         batch_offset,
         target_count,
         cards_by_key
       ) do
    batch = list_visible_candidates(user_id, opts, sort, batch_limit, batch_offset)
    cards_by_key = newest_canonical_cards(batch, cards_by_key)

    if map_size(cards_by_key) >= target_count or length(batch) < batch_limit do
      Map.values(cards_by_key)
    else
      collect_visible_cards(
        user_id,
        opts,
        sort,
        batch_limit,
        batch_offset + batch_limit,
        target_count,
        cards_by_key
      )
    end
  end

  defp list_visible_candidates(user_id, opts, sort, limit, offset) do
    user_id
    |> build_visible_query(opts)
    |> apply_series_sort(sort)
    |> limit(^limit)
    |> offset(^offset)
    |> select_card_fields()
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  def select_card_fields(query) do
    select(query, [s], struct(s, ^@card_fields))
  end

  def dedupe_variants(query) do
    key = canonical_key()

    representative_ids =
      query
      |> exclude(:order_by)
      |> exclude(:distinct)
      |> distinct(^[key])
      |> order_by(^[asc: key, desc: :id])
      |> select([s], s.id)

    from(s in Series, where: s.id in subquery(representative_ids))
  end

  @spec list_public(keyword()) :: [Series.t()]
  def list_public(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Series
    |> Access.public_providers()
    |> where([s, _p], not is_nil(s.cover))
    |> order_by([s], desc: s.rating, desc: s.year, asc: s.name)
    |> limit(^limit)
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  @spec count(integer(), keyword()) :: integer()
  def count(provider_id, opts \\ []) do
    has_category = Keyword.get(opts, :category_id) != nil

    provider_id
    |> build_filtered_query(opts)
    |> exclude(:distinct)
    |> count_query(has_category)
    |> Repo.one()
  end

  @spec get_by_ids([integer()]) :: [Series.t()]
  def get_by_ids([]), do: []

  def get_by_ids(ids) when is_list(ids) do
    from(s in Series, where: s.id in ^ids)
    |> preload(^@search_result_preloads)
    |> Repo.all()
  end

  @spec get_playable(integer(), integer()) :: Series.t() | nil
  def get_playable(user_id, series_id) do
    Series
    |> Access.playable(user_id, series_id)
    |> preload(^[:provider | @detail_preloads])
    |> Repo.one()
  end

  @spec get_public(integer()) :: Series.t() | nil
  def get_public(series_id) do
    Series
    |> Access.public_only(series_id)
    |> preload(^[:provider | @detail_preloads])
    |> Repo.one()
  end

  @spec get_with_seasons(integer()) :: Series.t() | nil
  def get_with_seasons(id) do
    Series
    |> where(id: ^id)
    |> preload(seasons: ^{public_seasons_query(), episodes: public_episodes_query()})
    |> preload(^[:provider | @detail_preloads])
    |> Repo.one()
  end

  @spec get_with_seasons!(integer()) :: Series.t()
  def get_with_seasons!(id) do
    Series
    |> where(id: ^id)
    |> preload(seasons: ^{public_seasons_query(), episodes: public_episodes_query()})
    |> preload(^[:provider | @detail_preloads])
    |> Repo.one!()
  end

  @spec get_episode_for_stream(integer()) :: Episode.t() | nil
  def get_episode_for_stream(id) do
    Episode
    |> where(id: ^id)
    |> preload(season: [series: :provider])
    |> Repo.one()
  end

  @spec get_user_episode(integer(), integer()) :: Episode.t() | nil
  def get_user_episode(user_id, episode_id) do
    Episode
    |> join(:inner, [e], s in Season, on: e.season_id == s.id)
    |> join(:inner, [_e, s], sr in Series, on: s.series_id == sr.id)
    |> join(:inner, [_e, _s, sr], p in Provider, on: sr.provider_id == p.id)
    |> where([e, _s, _sr, p], e.id == ^episode_id and p.user_id == ^user_id)
    |> preload(season: [series: :provider])
    |> Repo.one()
  end

  @spec get_playable_episode(integer(), integer()) :: Episode.t() | nil
  def get_playable_episode(user_id, episode_id) do
    Episode
    |> join(:inner, [e], s in Season, on: e.season_id == s.id)
    |> join(:inner, [_e, s], sr in Series, on: s.series_id == sr.id)
    |> join(:inner, [_e, _s, sr], p in Provider, on: sr.provider_id == p.id)
    |> where([e, _s, _sr, _p], e.id == ^episode_id)
    |> where([_e, _s, _sr, p], p.visibility in [:global, :public] or p.user_id == ^user_id)
    |> preload(season: [series: :provider])
    |> Repo.one()
  end

  @spec get_public_episode(integer()) :: Episode.t() | nil
  def get_public_episode(episode_id) do
    Episode
    |> join(:inner, [e], s in Season, on: e.season_id == s.id)
    |> join(:inner, [_e, s], sr in Series, on: s.series_id == sr.id)
    |> join(:inner, [_e, _s, sr], p in Provider, on: sr.provider_id == p.id)
    |> where([e, _s, _sr, _p], e.id == ^episode_id)
    |> where([_e, _s, _sr, p], p.visibility in [:global, :public])
    |> preload(season: [series: :provider])
    |> Repo.one()
  end

  @spec get_episode_with_context!(integer()) :: Episode.t()
  def get_episode_with_context!(id) do
    Episode
    |> where(id: ^id)
    |> preload(season: [series: [:provider, :assets]])
    |> Repo.one!()
  end

  @spec list_season_episodes(integer()) :: [Episode.t()]
  def list_season_episodes(season_id) do
    Episode
    |> where(season_id: ^season_id)
    |> order_by(:episode_num)
    |> Repo.all()
  end

  @spec get_next_episode(integer()) :: Episode.t() | nil
  def get_next_episode(episode_id) do
    episode = Repo.get(Episode, episode_id)
    if episode, do: find_next_episode(episode), else: nil
  end

  @spec search(integer(), String.t(), keyword()) :: [Series.t()]
  def search(user_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)
    escaped = Helpers.escape_like(query)

    Series
    |> Access.visible_to_user(user_id)
    |> where([s, _p], ilike(s.name, ^"%#{escaped}%") or ilike(s.title, ^"%#{escaped}%"))
    |> order_by([s], desc: s.rating, asc: s.name)
    |> limit(^limit)
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  @spec search_public(String.t(), keyword()) :: [Series.t()]
  def search_public(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)

    Series
    |> Access.public_providers()
    |> RankedSearch.build([:name, :title], query, limit: limit)
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  @spec list_variants(Series.t(), integer(), keyword()) :: [Series.t()]
  def list_variants(%Series{} = series, user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 12)
    candidate_limit = max(limit * 4, 32)
    tmdb_id = blank_to_nil(series.tmdb_id)
    normalized_title = normalize_variant_title(series.title || series.name)
    search_title = variant_search_title(series)

    tmdb_variants =
      case tmdb_id do
        nil -> []
        tmdb_id -> variants_by_tmdb_id(tmdb_id, user_id, limit)
      end

    title_variants =
      case {series.year, normalized_title, search_title} do
        {nil, _, _} ->
          []

        {_, "", _} ->
          []

        {_, _, ""} ->
          []

        {year, _, _} ->
          variants_by_title(search_title, normalized_title, year, user_id, candidate_limit)
      end

    (tmdb_variants ++ title_variants)
    |> Enum.uniq_by(& &1.id)
    |> Enum.filter(&has_playable_episodes?/1)
    |> Enum.sort_by(fn series -> {-series.id, provider_sort_name(series)} end)
    |> Enum.take(limit)
  end

  defp variants_by_tmdb_id(tmdb_id, user_id, limit) do
    Series
    |> Access.visible_to_user(user_id)
    |> where([s, _p], s.tmdb_id == ^tmdb_id)
    |> order_by([s, p], desc: s.id, asc: p.name)
    |> limit(^limit)
    |> preload(^variant_preloads())
    |> Repo.all()
  end

  defp variants_by_title(search_title, normalized_title, year, user_id, limit) do
    Series
    |> Access.visible_to_user(user_id)
    |> where([s, _p], s.year == ^year)
    |> where(
      [s, _p],
      fragment("? % ?", ^search_title, s.name) or
        fragment("? % coalesce(?, '')", ^search_title, s.title)
    )
    |> order_by(
      [s, p],
      desc:
        fragment(
          "GREATEST(similarity(?, ?), similarity(?, coalesce(?, '')))",
          ^search_title,
          s.name,
          ^search_title,
          s.title
        ),
      desc: s.id,
      asc: p.name
    )
    |> limit(^limit)
    |> preload(^variant_preloads())
    |> Repo.all()
    |> Enum.filter(&(normalize_variant_title(&1.title || &1.name) == normalized_title))
  end

  @spec count_episodes_for_series(integer()) :: integer()
  def count_episodes_for_series(series_id) do
    Episode
    |> join(:inner, [e], s in Season, on: e.season_id == s.id)
    |> where([_e, s], s.series_id == ^series_id)
    |> Repo.aggregate(:count)
  end

  defp build_filtered_query(provider_id, opts) do
    search = Keyword.get(opts, :search)
    category_id = Keyword.get(opts, :category_id)
    show_adult = Keyword.get(opts, :show_adult, false)

    Series
    |> where(provider_id: ^provider_id)
    |> maybe_where_search(search)
    |> maybe_join_category(category_id)
    |> maybe_exclude_adult(provider_id, show_adult)
  end

  defp build_visible_query(user_id, opts) do
    search = Keyword.get(opts, :search)
    show_adult = Keyword.get(opts, :show_adult, false)
    genre_id = Keyword.get(opts, :genre_id)

    Series
    |> Access.visible_to_user(user_id)
    |> where([_s, p], p.provider_type == :xtream and p.is_active == true)
    |> maybe_where_search(search)
    |> maybe_join_genre(genre_id)
    |> maybe_exclude_adult(show_adult)
  end

  defp maybe_dedupe_variants(query, true), do: dedupe_variants(query)
  defp maybe_dedupe_variants(query, _), do: query

  defp maybe_where_search(query, nil), do: query
  defp maybe_where_search(query, ""), do: query

  defp maybe_where_search(query, search) do
    escaped = Helpers.escape_like(search)
    compacted = compact_search(search)

    where(
      query,
      [s],
      ilike(s.name, ^"%#{escaped}%") or
        ilike(s.title, ^"%#{escaped}%") or
        fragment(
          "regexp_replace(lower(coalesce(?, ?)), '[^[:alnum:]]+', '', 'g') LIKE ?",
          s.title,
          s.name,
          ^"%#{compacted}%"
        )
    )
  end

  defp maybe_join_category(query, nil), do: query

  defp maybe_join_category(query, category_id) do
    query
    |> join(:inner, [s], ic in "item_categories",
      on: ic.catalog_item_id == s.catalog_item_id and ic.category_id == ^category_id
    )
    |> distinct([s], s.id)
  end

  defp maybe_join_genre(query, nil), do: query

  defp maybe_join_genre(query, genre_id) do
    query
    |> join(:inner, [s], sg in "series_genres",
      on: sg.series_id == s.id and sg.genre_id == ^genre_id
    )
    |> distinct([s], s.id)
  end

  defp maybe_exclude_adult(query, _provider_id, true), do: query

  defp maybe_exclude_adult(query, provider_id, _show_adult),
    do: AdultFilter.exclude_adult_series(query, provider_id)

  defp maybe_exclude_adult(query, true), do: query
  defp maybe_exclude_adult(query, _show_adult), do: AdultFilter.exclude_adult_content(query)

  defp apply_series_sort(query, "rating_desc"),
    do:
      order_by(query, [s], [
        fragment("? DESC NULLS LAST", s.rating),
        desc: s.year,
        asc: s.name,
        desc: s.id
      ])

  defp apply_series_sort(query, "created_desc"),
    do: order_by(query, [s], desc: s.inserted_at, desc: s.id)

  defp apply_series_sort(query, "year_desc"),
    do: order_by(query, [s], [fragment("? DESC NULLS LAST", s.year), asc: s.name, desc: s.id])

  defp apply_series_sort(query, "name_asc"), do: order_by(query, [s], asc: s.name, desc: s.id)

  defp apply_series_sort(query, _),
    do: order_by(query, [s], desc: s.year, asc: s.name, desc: s.id)

  defp count_query(query, true), do: select(query, [s], count(s.id, :distinct))
  defp count_query(query, false), do: select(query, [s], count(s.id))

  defp compact_search(search) when is_binary(search) do
    search
    |> String.downcase()
    |> String.replace(~r/[^[:alnum:]]+/u, "")
    |> Helpers.escape_like()
  end

  defp compact_search(_), do: ""

  defp canonical_key do
    dynamic(
      [s],
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
        s.tmdb_id,
        s.tmdb_id,
        s.title,
        s.name,
        s.year
      )
    )
  end

  defp has_playable_episodes?(%{seasons: seasons}) when is_list(seasons) do
    Enum.any?(seasons, fn season -> season.episodes != [] end)
  end

  defp has_playable_episodes?(_series), do: false

  defp variant_preloads do
    [:provider, :categories, seasons: {public_seasons_query(), episodes: public_episodes_query()}]
  end

  defp provider_sort_name(%{provider: %{name: name}}) when is_binary(name), do: name
  defp provider_sort_name(_), do: ""

  defp variant_search_title(%Series{} = series) do
    series.title
    |> blank_to_nil()
    |> Kernel.||(series.name)
    |> strip_variant_terms()
  end

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp normalize_variant_title(value) when is_binary(value) do
    value
    |> strip_variant_terms()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_variant_title(_), do: ""

  defp canonical_variant_key(%Series{} = series) do
    case blank_to_nil(series.tmdb_id) do
      nil -> {:title, normalize_variant_title(series.title || series.name), series.year}
      tmdb_id -> {:tmdb, tmdb_id}
    end
  end

  defp newest_canonical_cards(series, cards_by_key) do
    series
    |> Enum.reduce(cards_by_key, fn item, acc ->
      Map.update(acc, canonical_variant_key(item), item, &newer_card(item, &1))
    end)
  end

  defp newer_card(item, current) do
    if item.id > current.id, do: item, else: current
  end

  defp sort_visible_cards(series, "rating_desc") do
    Enum.sort_by(series, fn item ->
      {desc_numeric(item.rating), desc_year(item.year), item.name || "", -item.id}
    end)
  end

  defp sort_visible_cards(series, "created_desc") do
    Enum.sort_by(series, fn item ->
      {desc_datetime(item.inserted_at), -item.id}
    end)
  end

  defp sort_visible_cards(series, "name_asc") do
    Enum.sort_by(series, fn item -> {item.name || "", -item.id} end)
  end

  defp sort_visible_cards(series, _sort) do
    Enum.sort_by(series, fn item -> {desc_year(item.year), item.name || "", -item.id} end)
  end

  defp desc_numeric(%Decimal{} = value), do: -Decimal.to_float(value)
  defp desc_numeric(value) when is_number(value), do: -value
  defp desc_numeric(_value), do: 1_000_000_000

  defp desc_year(year) when is_integer(year), do: -year
  defp desc_year(_year), do: 1_000_000_000

  defp desc_datetime(%DateTime{} = datetime), do: -DateTime.to_unix(datetime, :microsecond)

  defp desc_datetime(%NaiveDateTime{} = datetime),
    do: -NaiveDateTime.diff(datetime, ~N[1970-01-01 00:00:00], :microsecond)

  defp desc_datetime(_datetime), do: 1_000_000_000_000_000

  defp strip_variant_terms(value) when is_binary(value) do
    value
    |> String.replace(~r/\s*\[[^\]]+\]/u, " ")
    |> String.replace(@variant_terms, " ")
    |> String.replace(~r/[[:punct:]]+/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp strip_variant_terms(_), do: ""

  defp public_seasons_query do
    from(s in Season, where: s.season_number > 0, order_by: s.season_number)
  end

  defp public_episodes_query do
    from(e in Episode, order_by: e.episode_num)
  end

  defp find_next_episode(episode) do
    episode = Repo.preload(episode, season: :series)
    season = episode.season

    next_in_season =
      Episode
      |> where([e], e.season_id == ^season.id)
      |> where([e], e.episode_num > ^episode.episode_num)
      |> order_by([e], asc: e.episode_num)
      |> limit(1)
      |> preload(season: [series: :provider])
      |> Repo.one()

    if next_in_season do
      next_in_season
    else
      find_first_episode_in_next_season(season)
    end
  end

  defp find_first_episode_in_next_season(season) do
    next_season =
      Season
      |> where([s], s.series_id == ^season.series_id)
      |> where([s], s.season_number > ^season.season_number)
      |> order_by([s], asc: s.season_number)
      |> limit(1)
      |> Repo.one()

    if next_season do
      Episode
      |> where([e], e.season_id == ^next_season.id)
      |> order_by([e], asc: e.episode_num)
      |> limit(1)
      |> preload(season: [series: :provider])
      |> Repo.one()
    end
  end
end
