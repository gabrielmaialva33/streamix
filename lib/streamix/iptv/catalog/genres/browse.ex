defmodule Streamix.Iptv.Genres.Browse do
  @moduledoc """
  Canonical genre facets for aggregate IPTV browsing.

  Counts are computed in SQL as distinct titles per genre, a title being its
  TMDB id or, without one, its name. That approximates the listing's variant
  deduplication (which also merges localized names and "4K" copies) closely
  enough for a filter chip, without loading every visible title: exact
  clustering took seconds per call on a production-sized catalog. Counts are
  cached for 10 minutes; the title listing itself always checks visibility.
  """

  import Ecto.Query

  alias Streamix.Cache
  alias Streamix.Cache.Keys
  alias Streamix.Iptv.Content.Movies.Queries
  alias Streamix.Iptv.Content.SeriesOps.ListingQuery
  alias Streamix.Iptv.Genre
  alias Streamix.Iptv.Genres.Vocabulary
  alias Streamix.Repo

  @ttl 600

  @spec list_visible(:movies | :series, integer() | nil, keyword()) :: [map()]
  def list_visible(kind, user_id, opts \\ []) when kind in [:movies, :series] do
    show_adult = Keyword.get(opts, :show_adult, false) == true

    Cache.fetch(Keys.visible_genres(kind, user_id, show_adult), @ttl, fn ->
      counts = kind |> query(user_id, show_adult: show_adult) |> Repo.all() |> Map.new()

      for %{slug: slug, name: name} <- Vocabulary.all(), count = counts[slug] do
        %{slug: slug, name: name, count: count}
      end
    end)
  end

  @doc false
  def filter(query, _kind, nil), do: query

  def filter(query, :movies, slug) do
    where(
      query,
      [item],
      fragment(
        "EXISTS (SELECT 1 FROM movie_genres l JOIN genres g ON g.id = l.genre_id WHERE l.movie_id = ? AND g.slug = ?)",
        item.id,
        ^slug
      )
    )
  end

  def filter(query, :series, slug) do
    where(
      query,
      [item],
      fragment(
        "EXISTS (SELECT 1 FROM series_genres l JOIN genres g ON g.id = l.genre_id WHERE l.series_id = ? AND g.slug = ?)",
        item.id,
        ^slug
      )
    )
  end

  @doc false
  def query(kind, user_id, opts) do
    {module, table, fk} = config(kind)

    user_id
    |> module.filtered_visible(Keyword.take(opts, [:show_adult]))
    |> join(:inner, [item], link in ^table, on: field(link, ^fk) == item.id)
    |> join(:inner, [..., link], genre in Genre, on: genre.id == link.genre_id)
    |> where([..., genre], genre.slug in ^Vocabulary.slugs())
    |> group_by([..., genre], genre.slug)
    |> select(
      [item, ..., genre],
      {genre.slug,
       count(fragment("DISTINCT coalesce(nullif(?, ''), lower(?))", item.tmdb_id, item.name))}
    )
  end

  defp config(:movies), do: {Queries, "movie_genres", :movie_id}
  defp config(:series), do: {ListingQuery, "series_genres", :series_id}
end
