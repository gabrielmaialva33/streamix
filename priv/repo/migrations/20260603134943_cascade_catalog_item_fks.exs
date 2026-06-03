defmodule Streamix.Repo.Migrations.CascadeCatalogItemFks do
  @moduledoc """
  Switch `watch_party_rooms.catalog_item_id` and `episodes.catalog_item_id`
  from ON DELETE RESTRICT to ON DELETE CASCADE.

  RESTRICT was forcing the orphan cleanup pipeline to delete dependent rows
  by hand in a precise order, and a recent provider migration hit a
  foreign_key_violation when a catalog_items row referenced by a watch
  party room was eligible for orphan removal. CASCADE lets the cleanup
  pass drop the catalog_item directly and lets Postgres tear down the
  dangling rooms (and their participants/messages, which already cascade
  from the room) atomically.

  These tables already track the conceptual lifetime of the catalog_item:
  a room or episode without its content row has no reason to live.
  """
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE watch_party_rooms
      DROP CONSTRAINT IF EXISTS watch_party_rooms_catalog_item_id_fkey
    """)

    execute("""
    ALTER TABLE watch_party_rooms
      ADD CONSTRAINT watch_party_rooms_catalog_item_id_fkey
      FOREIGN KEY (catalog_item_id) REFERENCES catalog_items(id)
      ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE episodes
      DROP CONSTRAINT IF EXISTS episodes_catalog_item_id_fkey
    """)

    execute("""
    ALTER TABLE episodes
      ADD CONSTRAINT episodes_catalog_item_id_fkey
      FOREIGN KEY (catalog_item_id) REFERENCES catalog_items(id)
      ON DELETE CASCADE
    """)
  end

  def down do
    execute("""
    ALTER TABLE watch_party_rooms
      DROP CONSTRAINT IF EXISTS watch_party_rooms_catalog_item_id_fkey
    """)

    execute("""
    ALTER TABLE watch_party_rooms
      ADD CONSTRAINT watch_party_rooms_catalog_item_id_fkey
      FOREIGN KEY (catalog_item_id) REFERENCES catalog_items(id)
      ON DELETE RESTRICT
    """)

    execute("""
    ALTER TABLE episodes
      DROP CONSTRAINT IF EXISTS episodes_catalog_item_id_fkey
    """)

    execute("""
    ALTER TABLE episodes
      ADD CONSTRAINT episodes_catalog_item_id_fkey
      FOREIGN KEY (catalog_item_id) REFERENCES catalog_items(id)
      ON DELETE RESTRICT
    """)
  end
end
