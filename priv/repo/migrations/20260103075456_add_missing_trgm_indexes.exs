defmodule Streamix.Repo.Migrations.AddMissingTrgmIndexes do
  use Ecto.Migration

  @moduledoc """
  Adds missing pg_trgm indexes for text search optimization.

  The pg_trgm extension enables efficient ILIKE queries with wildcards
  by using GIN indexes on trigram decomposition of text.

  Without these indexes, queries like `WHERE name ILIKE '%term%'`
  require full table scans. With GIN trigram indexes, PostgreSQL
  can use index scans for much better performance.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Create indexes concurrently to avoid locking tables
    # These are safe to run on production with active traffic

    # Series title index (searches use both name and title)
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS series_title_trgm_idx
    ON series USING gin (title gin_trgm_ops)
    """

    # Movies title index (searches use both name and title)
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS movies_title_trgm_idx
    ON movies USING gin (title gin_trgm_ops)
    """

    # Movies genre index (catalog filtering by genre)
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS movies_genre_trgm_idx
    ON movies USING gin (genre gin_trgm_ops)
    """

    # Categories name index (category listing and filtering)
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS categories_name_trgm_idx
    ON categories USING gin (name gin_trgm_ops)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS series_title_trgm_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS movies_title_trgm_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS movies_genre_trgm_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS categories_name_trgm_idx"
  end
end
