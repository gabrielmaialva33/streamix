defmodule Streamix.Repo.Migrations.SealPersonalLibrary do
  @moduledoc """
  Moves watch history and favorites to rows sealed with a per-user key that
  only the user's password (or a live session secret held by the client) can
  open. See docs/privacy.md.

  The plaintext tables are renamed to `legacy_*`: their rows are sealed and
  deleted at each user's next login (`Streamix.Library.LegacyImport`), because
  sealing needs the password. `watch_events` had no reader and held content
  next to IP addresses, so it is dropped outright, and `playback_sessions` stops
  recording which content a screen slot was playing.
  """

  use Ecto.Migration

  def up do
    create table(:library_keys, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), primary_key: true
      add :salt, :binary, null: false
      add :iterations, :integer, null: false
      add :wrapped_key, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    alter table(:users_tokens) do
      add :library_key, :binary
    end

    rename table(:watch_progress), to: table(:legacy_watch_progress)

    rename_relations("watch_progress", "legacy_watch_progress", [
      "watch_progress_pkey",
      "watch_progress_user_id_catalog_item_id_index",
      "watch_progress_catalog_item_id_index",
      "watch_progress_continue_watching_idx"
    ])

    execute "ALTER SEQUENCE IF EXISTS watch_progress_id_seq RENAME TO legacy_watch_progress_id_seq"

    rename_constraints("legacy_watch_progress", [
      {"watch_progress_user_id_fkey", "legacy_watch_progress_user_id_fkey"},
      {"watch_progress_catalog_item_id_fkey", "legacy_watch_progress_catalog_item_id_fkey"}
    ])

    rename table(:favorites), to: table(:legacy_favorites)

    rename_relations("favorites", "legacy_favorites", [
      "favorites_pkey",
      "favorites_catalog_item_id_index"
    ])

    rename_constraints("legacy_favorites", [
      {"favorites_user_id_fkey", "legacy_favorites_user_id_fkey"},
      {"favorites_catalog_item_id_fkey", "legacy_favorites_catalog_item_id_fkey"}
    ])

    # Only the owner's key can tell which content a row points at:
    # `item_digest` is an HMAC under that key and `sealed` is AES-256-GCM
    # ciphertext. Nothing here references catalog_items, and there are no
    # plaintext timestamps: when something was watched or favorited lives
    # inside `sealed` too, so it cannot be matched against other records.
    create table(:watch_progress) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :item_digest, :binary, null: false
      add :sealed, :binary, null: false
    end

    create unique_index(:watch_progress, [:user_id, :item_digest])

    create table(:favorites) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :item_digest, :binary, null: false
      add :sealed, :binary, null: false
    end

    create unique_index(:favorites, [:user_id, :item_digest])

    # When a sync replaces a catalog item, sealed rows that point at it are
    # moved by their owner's next read. No foreign keys: the replaced item is
    # deleted right after, and a successor may itself be replaced later
    # (CatalogItemRedirect.record/1 re-points the chain).
    create table(:catalog_item_redirects, primary_key: false) do
      add :catalog_item_id, :bigint, primary_key: true
      add :successor_id, :bigint, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:catalog_item_redirects, [:successor_id])

    drop table(:watch_events)

    alter table(:playback_sessions) do
      remove :content_type
      remove :content_id
    end

    # Ended slots are no longer kept (they were a record of when each user
    # watched), and a room id would tie a slot to a Watch Party's content.
    execute "DELETE FROM playback_sessions WHERE status = 'ended'"
    execute "UPDATE playback_sessions SET metadata = metadata - 'room_id'"

    # A playback sample says when and what kind of content someone played;
    # it no longer says who (Streamix.Qoe keys its dedupe hash instead).
    alter table(:qoe_events) do
      remove :user_id
    end

    # Profile refreshes now run inside the user's session; queued jobs could
    # no longer read the history they were scheduled for.
    execute "DELETE FROM oban_jobs WHERE worker = 'Streamix.Workers.UpdateUserProfileWorker'"
  end

  def down do
    alter table(:qoe_events) do
      add :user_id, references(:users, on_delete: :nilify_all)
    end

    create index(:qoe_events, [:user_id, :inserted_at])

    alter table(:playback_sessions) do
      add :content_type, :string, null: false, default: "movie"
      add :content_id, :integer, null: false, default: 0
    end

    create table(:watch_events) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :catalog_item_id, references(:catalog_items, on_delete: :delete_all), null: false
      add :watched_at, :utc_datetime, null: false
      add :session_seconds, :integer
      add :progress_seconds, :integer
      add :completed, :boolean, null: false, default: false
      add :ip_address, :inet
      add :device_type, :string

      add :inserted_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:watch_events, [:user_id, :watched_at])
    create index(:watch_events, [:catalog_item_id])

    drop table(:catalog_item_redirects)

    # Sealed rows cannot be turned back into plaintext without each user's
    # key; rolling back keeps only what was never migrated.
    drop table(:favorites)
    drop table(:watch_progress)

    rename_constraints("legacy_favorites", [
      {"legacy_favorites_user_id_fkey", "favorites_user_id_fkey"},
      {"legacy_favorites_catalog_item_id_fkey", "favorites_catalog_item_id_fkey"}
    ])

    rename_relations("legacy_favorites", "favorites", [
      "legacy_favorites_pkey",
      "legacy_favorites_catalog_item_id_index"
    ])

    rename table(:legacy_favorites), to: table(:favorites)

    rename_constraints("legacy_watch_progress", [
      {"legacy_watch_progress_user_id_fkey", "watch_progress_user_id_fkey"},
      {"legacy_watch_progress_catalog_item_id_fkey", "watch_progress_catalog_item_id_fkey"}
    ])

    execute "ALTER SEQUENCE IF EXISTS legacy_watch_progress_id_seq RENAME TO watch_progress_id_seq"

    rename_relations("legacy_watch_progress", "watch_progress", [
      "legacy_watch_progress_pkey",
      "legacy_watch_progress_user_id_catalog_item_id_index",
      "legacy_watch_progress_catalog_item_id_index",
      "legacy_watch_progress_continue_watching_idx"
    ])

    rename table(:legacy_watch_progress), to: table(:watch_progress)

    alter table(:users_tokens) do
      remove :library_key
    end

    drop table(:library_keys)
  end

  # Index names are global relations, so the renamed table's indexes must move
  # out of the way before the new table claims the same names.
  defp rename_relations(from_prefix, to_prefix, names) do
    for name <- names do
      new_name = to_prefix <> String.replace_prefix(name, from_prefix, "")
      execute "ALTER INDEX IF EXISTS #{name} RENAME TO #{new_name}"
    end
  end

  defp rename_constraints(table, pairs) do
    for {from, to} <- pairs do
      execute """
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conname = '#{from}' AND conrelid = '#{table}'::regclass
        ) THEN
          ALTER TABLE #{table} RENAME CONSTRAINT #{from} TO #{to};
        END IF;
      END $$;
      """
    end
  end
end
