defmodule StreamixWeb.Content.SeriesSources do
  @moduledoc """
  The series-level source picker rule: which provider copies of a series are
  offered, in which order, and how much of each one is playable.

  This is the single definition of the rule: the series detail page and
  `GET /api/v1/catalog/series/:id/sources` both call `list/3` and `counts/1`,
  so the web and TV clients always offer the same copies in the same order.
  """

  alias StreamixWeb.Content.Detail
  alias StreamixWeb.Content.SourceBadges

  @doc """
  Returns the copies of `series` to offer, best first, one per provider.

  `series` must have its seasons and episodes preloaded (as
  `Streamix.Catalog.get_series_with_sync!/1` returns it). Equivalent copies
  come from `Streamix.Playback.list_series_variants/3` as seen by `user_id`
  (`nil` is an anonymous viewer). The requested series is added when it has a
  playable episode; the list is then ranked by
  `Streamix.Playback.sort_stream_sources/2` and only the best-ranked copy of
  each provider is kept.

  ## Options

    * `:preferred_provider_id` - provider the viewer explicitly asked for; it
      wins ties after availability and health, never over a working copy.
  """
  @spec list(map(), integer() | nil, keyword()) :: [map()]
  def list(series, user_id, opts \\ []) do
    series
    |> Detail.series_variants(user_id)
    |> ensure_current(series)
    |> Streamix.Playback.sort_stream_sources(
      media_type: :series,
      current_source_id: series.id,
      preferred_provider_id: Keyword.get(opts, :preferred_provider_id)
    )
    |> Enum.uniq_by(& &1.provider_id)
  end

  @doc """
  Returns `{season_count, episode_count}` for a copy, counting only seasons
  that have episodes. Works on the preloaded seasons, so it never queries.
  """
  @spec counts(map()) :: {non_neg_integer(), non_neg_integer()}
  def counts(series) do
    seasons = Detail.seasons_with_episodes(series)
    episode_count = Enum.reduce(seasons, 0, &(length(&1.episodes) + &2))

    {length(seasons), episode_count}
  end

  @doc "Presentation options for the authorized source list."
  def options(sources, user) do
    statuses = Streamix.Providers.provider_health_statuses(Enum.map(sources, & &1.provider))
    fullest = Enum.max_by(sources, &elem(counts(&1), 1), fn -> nil end)

    sources
    |> Enum.with_index()
    |> Enum.map(fn {source, index} ->
      %{
        id: source.id,
        label: source.provider.name,
        badges: SourceBadges.badges(source),
        note: availability_note(source, fullest),
        recommended: index == 0,
        unstable: Map.get(statuses, source.provider_id) == :degraded,
        locked: not Detail.premium_access?(user, source.provider)
      }
    end)
  end

  defp availability_note(source, fullest) do
    {_, count} = counts(source)
    {_, total} = counts(fullest)
    numbers = Enum.map(Detail.seasons_with_episodes(source), & &1.season_number)

    missing =
      fullest
      |> Detail.seasons_with_episodes()
      |> Enum.map(& &1.season_number)
      |> Enum.reject(&(&1 in numbers))
      |> Enum.map_join(", ", &"sem T#{&1}")

    [if(count < total, do: "#{count} de #{total} eps"), missing]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp ensure_current(sources, series) do
    cond do
      Enum.any?(sources, &(&1.id == series.id)) -> sources
      Detail.seasons_with_episodes(series) != [] -> [series | sources]
      true -> sources
    end
  end
end
