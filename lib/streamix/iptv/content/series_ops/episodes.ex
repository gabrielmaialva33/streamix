defmodule Streamix.Iptv.Content.SeriesOps.Episodes do
  alias Streamix.Iptv.Content.VodAvailability

  @moduledoc false

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Episode, Provider, Season, Series}
  alias Streamix.Repo

  @spec get_for_stream(integer()) :: Episode.t() | nil
  def get_for_stream(id) do
    Episode
    |> VodAvailability.exclude_dead()
    |> where(id: ^id)
    |> preload(season: [series: :provider])
    |> Repo.one()
  end

  @spec get_for_user(integer(), integer()) :: Episode.t() | nil
  def get_for_user(user_id, episode_id) do
    Episode
    |> episode_provider_query(episode_id)
    |> where([_episode, _season, _series, provider], provider.user_id == ^user_id)
    |> preload(season: [series: :provider])
    |> Repo.one()
  end

  @spec get_playable(integer(), integer()) :: Episode.t() | nil
  def get_playable(user_id, episode_id) do
    Episode
    |> episode_provider_query(episode_id)
    |> where(
      [_episode, _season, _series, provider],
      provider.visibility in [:global, :public] or provider.user_id == ^user_id
    )
    |> preload(season: [series: :provider])
    |> Repo.one()
  end

  @spec get_public(integer()) :: Episode.t() | nil
  def get_public(episode_id) do
    Episode
    |> episode_provider_query(episode_id)
    |> where([_episode, _season, _series, provider], provider.visibility in [:global, :public])
    |> preload(season: [series: :provider])
    |> Repo.one()
  end

  @spec get_with_context!(integer()) :: Episode.t()
  def get_with_context!(id) do
    Episode
    |> where(id: ^id)
    |> preload(season: [series: [:provider, :assets]])
    |> Repo.one!()
  end

  @spec list_for_season(integer()) :: [Episode.t()]
  def list_for_season(season_id) do
    Episode
    |> VodAvailability.exclude_dead()
    |> where(season_id: ^season_id)
    |> order_by(:episode_num)
    |> Repo.all()
  end

  @spec get_next(integer()) :: Episode.t() | nil
  def get_next(episode_id) do
    case Repo.get(Episode, episode_id) do
      nil -> nil
      episode -> find_next(episode)
    end
  end

  @spec count_for_series(integer()) :: non_neg_integer()
  def count_for_series(series_id) do
    Episode
    |> join(:inner, [episode], season in Season, on: episode.season_id == season.id)
    |> where([_episode, season], season.series_id == ^series_id)
    |> Repo.aggregate(:count)
  end

  defp episode_provider_query(query, episode_id) do
    query
    |> join(:inner, [episode], season in Season, on: episode.season_id == season.id)
    |> join(:inner, [_episode, season], series in Series, on: season.series_id == series.id)
    |> join(:inner, [_episode, _season, series], provider in Provider,
      on: series.provider_id == provider.id
    )
    |> where(
      [episode, _season, _series, provider],
      episode.id == ^episode_id and provider.is_active == true
    )
  end

  defp find_next(episode) do
    episode = Repo.preload(episode, :season)

    Episode
    |> VodAvailability.exclude_dead()
    |> join(:inner, [candidate], season in Season, on: candidate.season_id == season.id)
    |> where([candidate, season], season.series_id == ^episode.season.series_id)
    |> where(
      [candidate, season],
      season.season_number > ^episode.season.season_number or
        (season.season_number == ^episode.season.season_number and
           candidate.episode_num > ^episode.episode_num)
    )
    |> order_by([candidate, season], asc: season.season_number, asc: candidate.episode_num)
    |> limit(1)
    |> preload(season: [series: :provider])
    |> Repo.one()
  end
end
