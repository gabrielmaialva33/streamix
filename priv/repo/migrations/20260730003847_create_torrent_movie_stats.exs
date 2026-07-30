defmodule Streamix.Repo.Migrations.CreateTorrentMovieStats do
  use Ecto.Migration

  def up do
    execute("""
    CREATE MATERIALIZED VIEW torrent_movie_stats AS
    SELECT
      movie_id,
      max(seeders)::integer AS max_seeders,
      max(quality)::varchar AS top_quality
    FROM torrent_streams
    WHERE movie_id IS NOT NULL
    GROUP BY movie_id
    """)

    execute("""
    CREATE UNIQUE INDEX torrent_movie_stats_movie_id_idx
    ON torrent_movie_stats (movie_id)
    """)

    execute("""
    CREATE INDEX torrent_movie_stats_ranking_idx
    ON torrent_movie_stats (max_seeders DESC, movie_id DESC)
    """)
  end

  # migration-safety: reviewed — the materialized view is a derived read model;
  # dropping it never removes movies or torrent streams.
  def down do
    execute("DROP MATERIALIZED VIEW IF EXISTS torrent_movie_stats")
  end
end
