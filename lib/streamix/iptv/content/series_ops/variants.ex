defmodule Streamix.Iptv.Content.SeriesOps.Variants do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Access, Episode, Season, Series}
  alias Streamix.Iptv.Content.{SourceEquivalence, VariantCards}
  alias Streamix.Repo

  @spec list(Series.t(), integer(), keyword()) :: [Series.t()]
  def list(%Series{} = series, user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 12)
    candidate_limit = max(limit * 4, 32)
    tmdb_id = blank_to_nil(series.tmdb_id)
    normalized_title = VariantCards.normalize_title(series.title || series.name)
    search_title = variant_search_title(series)

    linked_variants =
      series.catalog_item_id
      |> SourceEquivalence.catalog_item_ids()
      |> by_catalog_item_ids(user_id, limit)

    tmdb_variants = if tmdb_id, do: by_tmdb_id(tmdb_id, user_id, limit), else: []

    title_variants =
      case {series.year, normalized_title, search_title} do
        {nil, _, _} -> []
        {_, "", _} -> []
        {_, _, ""} -> []
        {year, _, _} -> by_title(search_title, normalized_title, year, user_id, candidate_limit)
      end

    (linked_variants ++ tmdb_variants ++ title_variants)
    |> Enum.uniq_by(& &1.id)
    |> Enum.filter(&playable?/1)
    |> Enum.sort_by(fn candidate -> {-candidate.id, provider_sort_name(candidate)} end)
    |> Enum.take(limit)
  end

  defp by_tmdb_id(tmdb_id, user_id, limit) do
    Series
    |> Access.visible_to_user(user_id)
    |> where([series, _provider], series.tmdb_id == ^tmdb_id)
    |> order_by([series, provider], desc: series.id, asc: provider.name)
    |> limit(^limit)
    |> preload(^preloads())
    |> Repo.all()
  end

  defp by_catalog_item_ids([], _user_id, _limit), do: []

  defp by_catalog_item_ids(catalog_item_ids, user_id, limit) do
    Series
    |> Access.visible_to_user(user_id)
    |> where([series, _provider], series.catalog_item_id in ^catalog_item_ids)
    |> order_by([series, provider], desc: series.id, asc: provider.name)
    |> limit(^limit)
    |> preload(^preloads())
    |> Repo.all()
  end

  defp by_title(search_title, normalized_title, year, user_id, limit) do
    Series
    |> Access.visible_to_user(user_id)
    |> where([series, _provider], series.year == ^year)
    |> where(
      [series, _provider],
      fragment("? % ?", ^search_title, series.name) or
        fragment("? % coalesce(?, '')", ^search_title, series.title)
    )
    |> order_by(
      [series, provider],
      desc:
        fragment(
          "GREATEST(similarity(?, ?), similarity(?, coalesce(?, '')))",
          ^search_title,
          series.name,
          ^search_title,
          series.title
        ),
      desc: series.id,
      asc: provider.name
    )
    |> limit(^limit)
    |> preload(^preloads())
    |> Repo.all()
    |> Enum.filter(&(VariantCards.normalize_title(&1.title || &1.name) == normalized_title))
  end

  defp playable?(%{seasons: seasons}) when is_list(seasons) do
    Enum.any?(seasons, fn season -> season.episodes != [] end)
  end

  defp playable?(_series), do: false

  defp preloads do
    [:provider, :categories, seasons: {public_seasons_query(), episodes: public_episodes_query()}]
  end

  defp public_seasons_query do
    from(season in Season, where: season.season_number > 0, order_by: season.season_number)
  end

  defp public_episodes_query do
    from(episode in Episode, order_by: episode.episode_num)
  end

  defp provider_sort_name(%{provider: %{name: name}}) when is_binary(name), do: name
  defp provider_sort_name(_series), do: ""

  defp variant_search_title(%Series{} = series) do
    series.title
    |> blank_to_nil()
    |> Kernel.||(series.name)
    |> VariantCards.strip_variant_terms()
  end

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value
end
