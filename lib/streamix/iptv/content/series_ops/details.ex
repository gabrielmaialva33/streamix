defmodule Streamix.Iptv.Content.SeriesOps.Details do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Access, Episode, Season, Series}
  alias Streamix.Repo

  @detail_preloads [:assets, :genres, credits: :person]

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

  defp public_seasons_query do
    from(season in Season, where: season.season_number > 0, order_by: season.season_number)
  end

  defp public_episodes_query do
    from(episode in Episode, order_by: episode.episode_num)
  end
end
