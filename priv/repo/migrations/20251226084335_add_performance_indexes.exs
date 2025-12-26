defmodule Streamix.Repo.Migrations.AddPerformanceIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # Composite index for channel filtering by group and ordering
    # Covers: list_channels with group filter, get_categories
    create_if_not_exists index(:channels, [:provider_id, :group_title, :name],
                                concurrently: true)

    # Index for group_title alone (used in DISTINCT queries for categories)
    create_if_not_exists index(:channels, [:group_title],
                                concurrently: true,
                                where: "group_title IS NOT NULL")

    # Index for providers by user_id and is_active (used in list_user_channels)
    create_if_not_exists index(:providers, [:user_id, :is_active],
                                concurrently: true)

    # Index for favorites lookup
    create_if_not_exists index(:favorites, [:user_id, :inserted_at],
                                concurrently: true)

    # Index for watch_history ordering
    create_if_not_exists index(:watch_history, [:user_id, :watched_at],
                                concurrently: true)

    # Trigram index for ILIKE searches on channel names
    # Requires pg_trgm extension
    execute(
      "CREATE EXTENSION IF NOT EXISTS pg_trgm",
      "DROP EXTENSION IF EXISTS pg_trgm"
    )

    execute(
      """
      CREATE INDEX CONCURRENTLY IF NOT EXISTS channels_name_trgm_idx
      ON channels USING gin (name gin_trgm_ops)
      """,
      "DROP INDEX IF EXISTS channels_name_trgm_idx"
    )
  end
end
