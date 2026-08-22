defmodule Streamix.Repo.Migrations.HardenWatchPartyRooms do
  use Ecto.Migration

  # migration-safety: reviewed — expand-only schema changes; duplicate active
  # rooms are closed, not deleted, before the partial uniqueness constraint.
  # DROP statements appear only in reversible constraint rollback clauses.

  def change do
    alter table(:watch_party_rooms) do
      add :source_type, :string
      add :source_id, :bigint
      add :playback_state, :string, null: false, default: "paused"
      add :playback_position, :float, null: false, default: 0.0
      add :playback_buffering, :boolean, null: false, default: false
      add :playback_version, :bigint, null: false, default: 0
      add :playback_updated_at, :utc_datetime_usec
      add :last_activity_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :ended_reason, :string
    end

    create index(:watch_party_rooms, [:status, :last_activity_at],
             name: :watch_party_rooms_status_activity_idx
           )

    # Older builds created rooms as a GET side effect, so production may
    # already contain duplicate active rooms for the same host/content pair.
    # Keep the newest room active and close older duplicates before installing
    # the partial unique index that makes creation idempotent going forward.
    execute(
      """
      WITH ranked_rooms AS (
        SELECT
          id,
          row_number() OVER (
            PARTITION BY host_user_id, catalog_item_id
            ORDER BY inserted_at DESC, id DESC
          ) AS duplicate_rank
        FROM watch_party_rooms
        WHERE status = 'active'
      )
      UPDATE watch_party_rooms AS rooms
      SET
        status = 'ended',
        ended_at = COALESCE(rooms.ended_at, now()),
        ended_reason = 'migration_deduplicated',
        playback_state = 'paused',
        playback_buffering = false,
        last_activity_at = now(),
        updated_at = now()
      FROM ranked_rooms
      WHERE rooms.id = ranked_rooms.id
        AND ranked_rooms.duplicate_rank > 1
      """,
      "SELECT 1"
    )

    execute(
      """
      UPDATE watch_party_participants AS participants
      SET
        left_at = COALESCE(participants.left_at, now()),
        updated_at = now()
      FROM watch_party_rooms AS rooms
      WHERE participants.room_id = rooms.id
        AND participants.left_at IS NULL
        AND rooms.ended_reason = 'migration_deduplicated'
      """,
      "SELECT 1"
    )

    create unique_index(:watch_party_rooms, [:host_user_id, :catalog_item_id],
             where: "status = 'active'",
             name: :watch_party_rooms_host_content_active_unique
           )

    execute(
      """
      ALTER TABLE watch_party_rooms
      ADD CONSTRAINT watch_party_rooms_source_type_check
      CHECK (
        source_type IS NULL OR
        source_type IN ('live_channel', 'movie', 'episode', 'gindex', 'gindex_episode', 'torrent')
      )
      """,
      "ALTER TABLE watch_party_rooms DROP CONSTRAINT IF EXISTS watch_party_rooms_source_type_check"
    )

    execute(
      """
      ALTER TABLE watch_party_rooms
      ADD CONSTRAINT watch_party_rooms_source_ref_check
      CHECK (
        (source_type IS NULL AND source_id IS NULL) OR
        (source_type IS NOT NULL AND source_id IS NOT NULL AND source_id > 0)
      )
      """,
      "ALTER TABLE watch_party_rooms DROP CONSTRAINT IF EXISTS watch_party_rooms_source_ref_check"
    )

    execute(
      """
      ALTER TABLE watch_party_rooms
      ADD CONSTRAINT watch_party_rooms_playback_state_check
      CHECK (playback_state IN ('playing', 'paused'))
      """,
      "ALTER TABLE watch_party_rooms DROP CONSTRAINT IF EXISTS watch_party_rooms_playback_state_check"
    )

    execute(
      """
      ALTER TABLE watch_party_rooms
      ADD CONSTRAINT watch_party_rooms_playback_values_check
      CHECK (playback_position >= 0 AND playback_version >= 0)
      """,
      "ALTER TABLE watch_party_rooms DROP CONSTRAINT IF EXISTS watch_party_rooms_playback_values_check"
    )
  end
end
