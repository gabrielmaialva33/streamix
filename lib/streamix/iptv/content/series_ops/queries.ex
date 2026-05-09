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
  @card_fields ~w(id series_id provider_id catalog_item_id name title year cover rating plot gindex_path dub_available inserted_at updated_at)a

  @spec list(integer(), keyword()) :: [Series.t()]
  def list(provider_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    sort = Keyword.get(opts, :sort)

    provider_id
    |> build_filtered_query(opts)
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

  defp maybe_where_search(query, nil), do: query
  defp maybe_where_search(query, ""), do: query

  defp maybe_where_search(query, search) do
    escaped = Helpers.escape_like(search)
    where(query, [s], ilike(s.name, ^"%#{escaped}%"))
  end

  defp maybe_join_category(query, nil), do: query

  defp maybe_join_category(query, category_id) do
    query
    |> join(:inner, [s], ic in "item_categories",
      on: ic.catalog_item_id == s.catalog_item_id and ic.category_id == ^category_id
    )
    |> distinct([s], s.id)
  end

  defp maybe_exclude_adult(query, _provider_id, true), do: query

  defp maybe_exclude_adult(query, provider_id, _show_adult),
    do: AdultFilter.exclude_adult_series(query, provider_id)

  defp apply_series_sort(query, "rating_desc"),
    do: order_by(query, [s], [fragment("? DESC NULLS LAST", s.rating), desc: s.year, asc: s.name])

  defp apply_series_sort(query, "created_desc"),
    do: order_by(query, [s], desc: s.inserted_at)

  defp apply_series_sort(query, "year_desc"),
    do: order_by(query, [s], [fragment("? DESC NULLS LAST", s.year), asc: s.name])

  defp apply_series_sort(query, "name_asc"), do: order_by(query, [s], asc: s.name)
  defp apply_series_sort(query, _), do: order_by(query, [s], desc: s.year, asc: s.name)

  defp count_query(query, true), do: select(query, [s], count(s.id, :distinct))
  defp count_query(query, false), do: select(query, [s], count(s.id))

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
