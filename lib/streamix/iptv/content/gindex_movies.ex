defmodule Streamix.Iptv.Content.GindexMovies do
  alias Streamix.Iptv.Content.VodAvailability

  @moduledoc """
  GIndex-backed movie queries.
  """

  import Ecto.Query, warn: false

  alias Streamix.Helpers
  alias Streamix.Iptv.Genres.Browse
  alias Streamix.Iptv.Movie
  alias Streamix.Repo

  @doc """
  Lists GIndex movies, one per title.

  The Drive often holds a film several times (1080p, 4K, dubbed, a second
  folder); copies sharing a TMDB id collapse to one row, the copy with a
  poster and a TMDB title first (`versions/1` lists the others). Newest
  first, a film without a year last.

  Takes `:limit`, `:offset`, `:search`, `:year`, `:genre` (a genre slug) and
  `:show_adult`.
  """
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    representatives =
      from(m in filtered(opts),
        distinct: fragment("coalesce(nullif(?, ''), 'row:' || ?::text)", m.tmdb_id, m.id),
        order_by: [
          desc: fragment("coalesce(?, '') <> ''", m.stream_icon),
          desc: fragment("coalesce(?, '') <> ''", m.title),
          desc: m.id
        ],
        select: m.id
      )

    Movie
    |> where([m], m.id in subquery(representatives))
    |> order_by([m],
      desc_nulls_last: m.year,
      asc: fragment("lower(coalesce(nullif(?, ''), ?))", m.title, m.name),
      desc: m.id
    )
    |> limit(^limit)
    |> offset(^offset)
    |> preload(:provider)
    |> Repo.all()
  end

  @doc """
  The other Drive copies of a movie's title (same TMDB id), best named first.
  Empty for a movie without a TMDB id.
  """
  def versions(%Movie{tmdb_id: tmdb_id, id: id}) when is_binary(tmdb_id) and tmdb_id != "" do
    Movie
    |> VodAvailability.exclude_dead()
    |> where([m], not is_nil(m.gindex_path) and m.tmdb_id == ^tmdb_id and m.id != ^id)
    |> order_by([m], asc: m.name, asc: m.id)
    |> Repo.all()
  end

  def versions(%Movie{}), do: []

  @doc """
  Counts GIndex movie titles (copies of one TMDB title count once).
  """
  def count do
    Movie
    |> VodAvailability.exclude_dead()
    |> where([m], not is_nil(m.gindex_path))
    |> select(
      [m],
      count(fragment("DISTINCT coalesce(nullif(?, ''), 'row:' || ?::text)", m.tmdb_id, m.id))
    )
    |> Repo.one()
  end

  defp filtered(opts) do
    Movie
    |> VodAvailability.exclude_dead()
    |> where([m], not is_nil(m.gindex_path))
    |> maybe_search(Keyword.get(opts, :search))
    |> maybe_year(Keyword.get(opts, :year))
    |> maybe_exclude_adult(Keyword.get(opts, :show_adult, false))
    |> Browse.filter(:movies, Keyword.get(opts, :genre))
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
