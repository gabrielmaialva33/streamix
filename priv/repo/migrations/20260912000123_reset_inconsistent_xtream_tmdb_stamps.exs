defmodule Streamix.Repo.Migrations.ResetInconsistentXtreamTmdbStamps do
  use Ecto.Migration

  def up do
    # One-time repair of metadata erased by Xtream and torrent syncs. Each stamp
    # is cleared independently; recorded misses and other providers are untouched.
    for table <- ["movies", "series"] do
      execute("""
      UPDATE #{table} AS content
      SET tmdb_searched_at = CASE
            WHEN content.tmdb_id IS NULL OR BTRIM(content.tmdb_id) IN ('', '0')
              THEN NULL ELSE content.tmdb_searched_at END,
          tmdb_details_at = CASE
            WHEN content.plot IS NULL OR BTRIM(content.plot) = ''
              THEN NULL ELSE content.tmdb_details_at END
      FROM providers AS provider
      WHERE provider.id = content.provider_id
        AND provider.provider_type IN ('xtream', 'torrent')
        AND content.tmdb_miss_reason IS NULL
        AND (
          (content.tmdb_searched_at IS NOT NULL
            AND (content.tmdb_id IS NULL OR BTRIM(content.tmdb_id) IN ('', '0')))
          OR
          (content.tmdb_details_at IS NOT NULL
            AND (content.plot IS NULL OR BTRIM(content.plot) = ''))
        )
      """)
    end
  end

  # The original timestamps cannot be reconstructed. Rolling back leaves the
  # rows eligible for enrichment rather than inventing a successful processing time.
  def down, do: :ok
end
