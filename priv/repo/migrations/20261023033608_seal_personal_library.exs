defmodule Streamix.Repo.Migrations.SealPersonalLibrary do
  @moduledoc """
  Expand step of sealing watch history and favorites with a per-user key
  that only the user's password (or a live session secret held by the client)
  can open. See docs/privacy.md.

  Everything here is additive, so the release before this one keeps working
  against the migrated schema: during the seconds between this migration and
  the container swap, and after an image rollback.

    * Sealed rows go to new tables, `sealed_watch_progress` and
      `sealed_favorites`. The plaintext `watch_progress` and `favorites` stay
      as they are; each user's rows are sealed into the new tables and deleted
      from the old ones at their next login (`Streamix.Library.LegacyImport`),
      because sealing needs the password.
    * `playback_sessions.content_type`/`content_id` and `qoe_events.user_id`
      become nullable and are cleared; the new code never writes them.
    * `watch_events`, which had no reader and held content next to IP
      addresses, is emptied.

  The contract step, in a later release, retires the plaintext tables and the
  cleared columns once no deployable image reads them.
  """

  use Ecto.Migration

  def change do
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

    # Only the owner's key can tell which content a row points at:
    # `item_digest` is an HMAC under that key and `sealed` is AES-256-GCM
    # ciphertext. Nothing here references catalog_items, and there are no
    # plaintext timestamps: when something was watched or favorited lives
    # inside `sealed` too, so it cannot be matched against other records.
    create table(:sealed_watch_progress) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :item_digest, :binary, null: false
      add :sealed, :binary, null: false
    end

    create unique_index(:sealed_watch_progress, [:user_id, :item_digest])

    create table(:sealed_favorites) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :item_digest, :binary, null: false
      add :sealed, :binary, null: false
    end

    create unique_index(:sealed_favorites, [:user_id, :item_digest])

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

    # The new code records that a screen is in use, never what it plays. The
    # previous release still writes these columns, so they stay, nullable.
    alter table(:playback_sessions) do
      modify :content_type, :string, null: true, from: {:string, null: false}
      modify :content_id, :integer, null: true, from: {:integer, null: false}
    end

    # Ended slots are no longer kept (they were a record of when each user
    # watched), and a room id would tie a slot to a Watch Party's content.
    # Neither statement can be undone, nor needs to be.
    execute(
      """
      DELETE FROM playback_sessions WHERE status = 'ended'
      """,
      "SELECT 1"
    )

    execute(
      """
      UPDATE playback_sessions
      SET content_type = NULL, content_id = NULL, metadata = metadata - 'room_id'
      """,
      "SELECT 1"
    )

    # A playback sample says when and what kind of content someone played; it
    # no longer says who (Streamix.Qoe keys its dedupe hash instead).
    execute("UPDATE qoe_events SET user_id = NULL WHERE user_id IS NOT NULL", "SELECT 1")

    execute("DELETE FROM watch_events", "SELECT 1")

    # Profile refreshes now run inside the user's session; queued jobs could
    # no longer read the history they were scheduled for.
    execute(
      "DELETE FROM oban_jobs WHERE worker = 'Streamix.Workers.UpdateUserProfileWorker'",
      "SELECT 1"
    )
  end
end
