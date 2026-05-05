defmodule Streamix.Iptv.Content.GindexSeries do
  @moduledoc """
  GIndex-backed series and anime queries.
  """

  import Ecto.Query, warn: false

  alias Streamix.Helpers
  alias Streamix.Iptv.{Episode, Season, Series}
  alias Streamix.Repo

  @doc """
  Lists GIndex animes.
  """
  def list_animes(opts \\ []) do
    opts
    |> base_opts()
    |> then(fn %{limit: limit, offset: offset, search: search} ->
      Series
      |> where([s], not is_nil(s.gindex_path))
      |> where([s], ilike(s.gindex_path, "%anime%") or ilike(s.gindex_path, "%Anime%"))
      |> order_by(asc: :name)
      |> maybe_search(search)
      |> limit(^limit)
      |> offset(^offset)
      |> Repo.all()
    end)
  end

  @doc """
  Counts GIndex animes.
  """
  def count_animes do
    Series
    |> where([s], not is_nil(s.gindex_path))
    |> where([s], ilike(s.gindex_path, "%anime%") or ilike(s.gindex_path, "%Anime%"))
    |> Repo.aggregate(:count)
  end

  @doc """
  Gets a GIndex anime with seasons and episodes.
  """
  def get_anime_with_seasons(id) do
    Series
    |> where(id: ^id)
    |> where([s], not is_nil(s.gindex_path))
    |> where([s], ilike(s.gindex_path, "%anime%") or ilike(s.gindex_path, "%Anime%"))
    |> preload(seasons: ^{public_seasons_query(), episodes: public_episodes_query()})
    |> preload(:provider)
    |> Repo.one()
  end

  @doc """
  Lists GIndex series, excluding animes.
  """
  def list(opts \\ []) do
    opts
    |> base_opts()
    |> then(fn %{limit: limit, offset: offset, search: search} ->
      Series
      |> where([s], not is_nil(s.gindex_path))
      |> where([s], not ilike(s.gindex_path, "%anime%") and not ilike(s.gindex_path, "%Anime%"))
      |> order_by(desc: :year, asc: :name)
      |> maybe_search(search)
      |> limit(^limit)
      |> offset(^offset)
      |> Repo.all()
    end)
  end

  @doc """
  Counts GIndex series, excluding animes.
  """
  def count do
    Series
    |> where([s], not is_nil(s.gindex_path))
    |> where([s], not ilike(s.gindex_path, "%anime%") and not ilike(s.gindex_path, "%Anime%"))
    |> Repo.aggregate(:count)
  end

  @doc """
  Gets a GIndex series with seasons and episodes.
  """
  def get_with_seasons(id) do
    Series
    |> where(id: ^id)
    |> where([s], not is_nil(s.gindex_path))
    |> preload(seasons: ^{public_seasons_query(), episodes: public_episodes_query()})
    |> preload(:provider)
    |> Repo.one()
  end

  defp base_opts(opts) do
    %{
      limit: Keyword.get(opts, :limit, 100),
      offset: Keyword.get(opts, :offset, 0),
      search: Keyword.get(opts, :search)
    }
  end

  defp maybe_search(query, nil), do: query
  defp maybe_search(query, ""), do: query

  defp maybe_search(query, search) do
    escaped = Helpers.escape_like(search)
    where(query, [s], ilike(s.name, ^"%#{escaped}%") or ilike(s.title, ^"%#{escaped}%"))
  end

  defp public_seasons_query do
    from(s in Season, where: s.season_number > 0, order_by: s.season_number)
  end

  defp public_episodes_query do
    from(e in Episode, order_by: e.episode_num)
  end
end
