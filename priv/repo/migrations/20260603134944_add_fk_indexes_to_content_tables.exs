defmodule Streamix.Repo.Migrations.AddFkIndexesToContentTables do
  @moduledoc """
  Adds composite indexes covering the `(catalog_item_id, provider_id)`
  side of the composite FK from `movies`, `series` and `live_channels`
  to `catalog_items(id, provider_id)`.

  The catalog side already has a primary key on `(id, provider_id)`, so
  inserts/updates resolve fast. The referring side, however, gets
  sequentially scanned whenever Postgres validates a delete on
  `catalog_items` — which is a hot path during orphan cleanup.

  CONCURRENTLY so the build doesn't block writers on these tables.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS
      movies_catalog_item_id_provider_id_index
      ON movies (catalog_item_id, provider_id)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS
      series_catalog_item_id_provider_id_index
      ON series (catalog_item_id, provider_id)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS
      live_channels_catalog_item_id_provider_id_index
      ON live_channels (catalog_item_id, provider_id)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS movies_catalog_item_id_provider_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS series_catalog_item_id_provider_id_index")

    execute("DROP INDEX CONCURRENTLY IF EXISTS live_channels_catalog_item_id_provider_id_index")
  end
end
