defmodule Streamix.Torrent.Catalog do
  alias Streamix.Catalog, as: MediaCatalog

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

  alias Streamix.Cache
  alias Streamix.Providers
  alias Streamix.Repo
  alias Streamix.Torrent.StatsRefresher
  alias Streamix.Torrent.TorrentStream

  @default_limit 48

  @doc "The browser-safe system torrent provider identity, or `nil` when absent."
  def provider, do: Providers.get_torrent_provider_ref()

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
    opts = Keyword.put_new(opts, :limit, @default_limit)
    MediaCatalog.list_torrent_movies(provider.id, opts)
  end

  @doc "Total movie count for the torrent provider (0 when off)."
  def count_movies(opts \\ []) do
    case provider() do
      nil ->
        0

      provider ->
        show_adult = Keyword.get(opts, :show_adult, false)

        Cache.fetch_local(
          {__MODULE__, :movie_count, provider.id, show_adult},
          :timer.minutes(5),
          fn ->
            MediaCatalog.count_torrent_movies(provider.id, show_adult: show_adult)
          end
        )
    end
  end

  @doc false
  def refresh_stats(provider_id) when is_integer(provider_id) do
    case StatsRefresher.refresh() do
      :ok ->
        Cache.delete_local({__MODULE__, :movie_count, provider_id, false})
        Cache.delete_local({__MODULE__, :movie_count, provider_id, true})
        :ok

      {:error, reason} ->
        {:error, {:torrent_stats_refresh_failed, reason}}
    end
  end

  @doc """
  All streams for a movie, best first. Used by the detail page to list
  available qualities.

  Clean releases rank ahead of flagged ones (`release_flags`: unofficial
  dub, camera capture) whatever their swarm size; within each group the
  biggest swarm wins.
  """
  def streams_for_movie(movie_id) do
    from(ts in TorrentStream,
      where: ts.movie_id == ^movie_id,
      order_by: ^ranking()
    )
    |> Repo.all()
  end

  @doc """
  The single best stream to play for a movie, or `nil`: the clean release
  with the most seeders, falling back to a flagged one only when nothing
  clean exists.
  """
  def best_stream_for_movie(movie_id) do
    from(ts in TorrentStream,
      where: ts.movie_id == ^movie_id,
      order_by: ^ranking(),
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  TMDB ids the catalog already pairs with the given IMDb ids, as
  `%{imdb_id => tmdb_id}` (ambiguous pairings are left out).
  """
  @spec tmdb_ids_by_imdb([String.t()], keyword()) :: %{String.t() => String.t()}
  def tmdb_ids_by_imdb(imdb_ids, opts \\ [])
  def tmdb_ids_by_imdb([], _opts), do: %{}
  def tmdb_ids_by_imdb(imdb_ids, opts), do: MediaCatalog.torrent_tmdb_ids_by_imdb(imdb_ids, opts)

  defp ranking do
    [
      asc: dynamic([ts], fragment("cardinality(?) > 0", ts.release_flags)),
      desc: dynamic([ts], ts.seeders),
      desc: dynamic([ts], ts.id)
    ]
  end

  defdelegate upsert_movie(provider_id, attrs), to: MediaCatalog, as: :upsert_torrent_movie

  defdelegate get_movie_for_playback(movie_id),
    to: MediaCatalog,
    as: :get_torrent_movie_for_playback

  defdelegate list_movies_for_provider(provider_id, opts),
    to: MediaCatalog,
    as: :list_torrent_movies

  defdelegate count_movies_for_provider(provider_id, opts),
    to: MediaCatalog,
    as: :count_torrent_movies
end
