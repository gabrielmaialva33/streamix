defmodule Streamix.Iptv.Content.SeriesOps.Listings do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Streamix.Cache
  alias Streamix.Iptv.Content.SeriesOps.ListingQuery
  alias Streamix.Iptv.Content.VariantCards
  alias Streamix.Iptv.{RankedSearch, Series}
  alias Streamix.Repo

  @summary_preloads [:genres]
  @search_result_preloads [:assets, :genres]
  @visible_dedupe_min_window 120
  @visible_candidates_cache_ttl :timer.seconds(45)

  @spec list(integer(), keyword()) :: [Series.t()]
  def list(provider_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    sort = Keyword.get(opts, :sort)
    dedupe? = Keyword.get(opts, :dedupe, false)

    provider_id
    |> ListingQuery.filtered_provider(opts)
    |> maybe_dedupe_variants(dedupe?)
    |> ListingQuery.sorted(sort)
    |> limit(^limit)
    |> offset(^offset)
    |> ListingQuery.select_card_fields()
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

  @spec list_public(keyword()) :: [Series.t()]
  def list_public(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    show_adult = Keyword.get(opts, :show_adult, false)

    show_adult
    |> ListingQuery.public()
    |> where([series, _provider], not is_nil(series.cover))
    |> order_by([series], desc: series.rating, desc: series.year, asc: series.name)
    |> limit(^limit)
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  @spec count(integer(), keyword()) :: integer()
  def count(provider_id, opts \\ []) do
    has_category? = Keyword.get(opts, :category_id) != nil

    provider_id
    |> ListingQuery.filtered_provider(opts)
    |> exclude(:distinct)
    |> ListingQuery.count(has_category?)
    |> Repo.one()
  end

  @spec get_by_ids([integer()]) :: [Series.t()]
  def get_by_ids([]), do: []

  def get_by_ids(ids) when is_list(ids) do
    from(series in Series, where: series.id in ^ids)
    |> preload(^@search_result_preloads)
    |> Repo.all()
  end

  @spec list_visible_by_ids(integer(), [integer()], keyword()) :: [Series.t()]
  def list_visible_by_ids(_user_id, [], _opts), do: []

  def list_visible_by_ids(user_id, ids, opts) when is_list(ids) do
    ranked_ids = Enum.uniq(ids)

    series_by_id =
      user_id
      |> ListingQuery.filtered_visible(opts)
      |> where([series], series.id in ^ranked_ids)
      |> ListingQuery.select_card_fields()
      |> preload(^@summary_preloads)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    ranked_rows(ranked_ids, series_by_id)
  end

  @spec list_public_by_ids([integer()], keyword()) :: [Series.t()]
  def list_public_by_ids(ids, opts \\ [])
  def list_public_by_ids([], _opts), do: []

  def list_public_by_ids(ids, opts) when is_list(ids) do
    ranked_ids = Enum.uniq(ids)

    series_by_id =
      opts
      |> Keyword.get(:show_adult, false)
      |> ListingQuery.public()
      |> where([series], series.id in ^ranked_ids)
      |> ListingQuery.select_card_fields()
      |> preload(^@summary_preloads)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    ranked_rows(ranked_ids, series_by_id)
  end

  @spec search(integer(), String.t(), keyword()) :: [Series.t()]
  def search(user_id, query, opts \\ []) do
    list_visible(user_id,
      search: query,
      sort: "rating_desc",
      limit: Keyword.get(opts, :limit, 24),
      offset: Keyword.get(opts, :offset, 0),
      show_adult: Keyword.get(opts, :show_adult, false)
    )
  end

  @spec search_public(String.t(), keyword()) :: [Series.t()]
  def search_public(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)
    show_adult = Keyword.get(opts, :show_adult, false)

    show_adult
    |> ListingQuery.public()
    |> RankedSearch.build([:name, :title], query, limit: limit)
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  defp list_visible_deduped(user_id, opts, limit, offset, sort) do
    target_count = offset + limit
    batch_limit = max(limit * 4, @visible_dedupe_min_window)

    user_id
    |> collect_visible_cards(opts, sort, batch_limit, 0, target_count, VariantCards.new())
    |> sort_visible_cards(sort)
    |> Enum.slice(offset, limit)
    |> Repo.preload(@summary_preloads)
  end

  defp collect_visible_cards(
         user_id,
         opts,
         sort,
         batch_limit,
         batch_offset,
         target_count,
         clusters
       ) do
    batch = cached_visible_candidates(user_id, opts, sort, batch_limit, batch_offset)
    clusters = Enum.reduce(batch, clusters, &VariantCards.add(&2, &1))

    if VariantCards.count(clusters) >= target_count or length(batch) < batch_limit do
      VariantCards.cards(clusters)
    else
      collect_visible_cards(
        user_id,
        opts,
        sort,
        batch_limit,
        batch_offset + batch_limit,
        target_count,
        clusters
      )
    end
  end

  defp list_visible_candidates(user_id, opts, sort, limit, offset) do
    user_id
    |> list_visible_candidate_cards(opts, sort, limit, offset)
    |> Repo.preload(@summary_preloads)
  end

  defp cached_visible_candidates(user_id, opts, sort, limit, offset) do
    cache_key =
      {__MODULE__, :visible_candidates, user_id, visible_filter_key(opts), sort, limit, offset}

    Cache.fetch_local(cache_key, @visible_candidates_cache_ttl, fn ->
      list_visible_candidate_cards(user_id, opts, sort, limit, offset)
    end)
  end

  defp list_visible_candidate_cards(user_id, opts, sort, limit, offset) do
    user_id
    |> ListingQuery.filtered_visible(opts)
    |> ListingQuery.sorted(sort)
    |> limit(^limit)
    |> offset(^offset)
    |> ListingQuery.select_card_fields()
    |> Repo.all()
  end

  defp visible_filter_key(opts) do
    opts
    |> Keyword.drop([:dedupe, :limit, :offset])
    |> Enum.sort()
  end

  defp maybe_dedupe_variants(query, true), do: ListingQuery.dedupe_variants(query)
  defp maybe_dedupe_variants(query, _dedupe?), do: query

  defp ranked_rows(ids, rows_by_id) do
    Enum.flat_map(ids, fn id ->
      case Map.fetch(rows_by_id, id) do
        {:ok, row} -> [row]
        :error -> []
      end
    end)
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

  defp desc_datetime(%NaiveDateTime{} = datetime) do
    -NaiveDateTime.diff(datetime, ~N[1970-01-01 00:00:00], :microsecond)
  end

  defp desc_datetime(_datetime), do: 1_000_000_000_000_000
end
