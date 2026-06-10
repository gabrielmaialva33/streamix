defmodule Streamix.Torrent.Catalog do
  @moduledoc """
  Read model for the torrent catalog UI.

  The torrent aggregator surfaces movies whose playable streams live in
  `torrent_streams` (one row per quality/audio variant, keyed on
  `info_hash`). These queries power the dedicated torrent screen: list
  movies ranked by swarm health, and resolve the best stream to play.

  Kept separate from `Streamix.Iptv.Catalog` because the ranking signal
  (max seeders) and the "only movies that actually have a live magnet"
  filter are torrent-specific.
  """

  import Ecto.Query

  alias Streamix.Iptv.{Movie, TorrentProvider}
  alias Streamix.Repo
  alias Streamix.Torrent.TorrentStream

  @default_limit 48

  @doc "The system torrent provider row, or `nil` when the feature is off."
  def provider, do: TorrentProvider.get()

  @doc """
  Lists torrent movies ranked by swarm health (max seeders desc).

  Each `%Movie{}` carries the virtual `torrent_seeders` and
  `torrent_quality` fields so cards can badge swarm + quality without an
  N+1. Only movies with at least one `torrent_streams` row are returned.

  Opts: `:limit`, `:offset`, `:search`, `:show_adult`.
  """
  def list_movies(opts \\ []) do
    case provider() do
      nil -> []
      provider -> do_list_movies(provider, opts)
    end
  end

  defp do_list_movies(provider, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    offset = Keyword.get(opts, :offset, 0)
    search = opts[:search]

    agg =
      from ts in TorrentStream,
        where: not is_nil(ts.movie_id),
        group_by: ts.movie_id,
        select: %{
          movie_id: ts.movie_id,
          max_seeders: max(ts.seeders),
          top_quality: max(ts.quality)
        }

    query =
      from m in Movie,
        join: s in subquery(agg),
        on: s.movie_id == m.id,
        where: m.provider_id == ^provider.id,
        order_by: [desc: s.max_seeders, desc: m.id],
        limit: ^limit,
        offset: ^offset,
        select: %{m | torrent_seeders: s.max_seeders, torrent_quality: s.top_quality}

    query
    |> maybe_search(search)
    |> Repo.all()
  end

  defp maybe_search(query, search) when is_binary(search) and search != "" do
    pattern = "%#{search}%"
    where(query, [m], ilike(m.name, ^pattern) or ilike(m.title, ^pattern))
  end

  defp maybe_search(query, _), do: query

  @doc "Total movie count for the torrent provider (0 when off)."
  def count_movies do
    case provider() do
      nil -> 0
      provider -> Repo.aggregate(from(m in Movie, where: m.provider_id == ^provider.id), :count)
    end
  end

  @doc """
  All streams for a movie, best swarm first. Used by the detail page to
  list available qualities.
  """
  def streams_for_movie(movie_id) do
    from(ts in TorrentStream,
      where: ts.movie_id == ^movie_id,
      order_by: [desc: ts.seeders, desc: ts.id]
    )
    |> Repo.all()
  end

  @doc """
  The single best stream to play for a movie (most seeders), or `nil`.
  """
  def best_stream_for_movie(movie_id) do
    from(ts in TorrentStream,
      where: ts.movie_id == ^movie_id,
      order_by: [desc: ts.seeders, desc: ts.id],
      limit: 1
    )
    |> Repo.one()
  end
end
