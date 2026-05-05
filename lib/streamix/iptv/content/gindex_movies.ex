defmodule Streamix.Iptv.Content.GindexMovies do
  @moduledoc """
  GIndex-backed movie queries.
  """

  import Ecto.Query, warn: false

  alias Streamix.Helpers
  alias Streamix.Iptv.Movie
  alias Streamix.Repo

  @doc """
  Lists GIndex movies.
  """
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    search = Keyword.get(opts, :search)
    year = Keyword.get(opts, :year)
    show_adult = Keyword.get(opts, :show_adult, false)

    Movie
    |> where([m], not is_nil(m.gindex_path))
    |> order_by(desc: :year, asc: :name)
    |> maybe_search(search)
    |> maybe_year(year)
    |> maybe_exclude_adult(show_adult)
    |> limit(^limit)
    |> offset(^offset)
    |> preload(:provider)
    |> Repo.all()
  end

  @doc """
  Counts GIndex movies.
  """
  def count do
    Movie
    |> where([m], not is_nil(m.gindex_path))
    |> Repo.aggregate(:count)
  end

  defp maybe_search(query, nil), do: query
  defp maybe_search(query, ""), do: query

  defp maybe_search(query, search) do
    escaped = Helpers.escape_like(search)
    search_term = "%#{escaped}%"
    where(query, [m], ilike(m.name, ^search_term) or ilike(m.title, ^search_term))
  end

  defp maybe_year(query, nil), do: query
  defp maybe_year(query, year), do: where(query, year: ^year)

  defp maybe_exclude_adult(query, true), do: query

  defp maybe_exclude_adult(query, _show_adult) do
    where(query, [m], not ilike(m.name, "%xxx%") and not ilike(m.name, "%adult%"))
  end
end
