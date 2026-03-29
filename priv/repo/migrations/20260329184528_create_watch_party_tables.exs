defmodule Streamix.Repo.Migrations.CreateWatchPartyTables do
  use Ecto.Migration

  def change do
    create table(:watch_party_rooms) do
      add :invite_code, :string, null: false
      add :host_user_id, references(:users, on_delete: :delete_all), null: false
      add :content_type, :string, null: false
      add :content_id, :integer, null: false
      add :content_name, :string
      add :content_icon, :text
      add :status, :string, null: false, default: "active"
      add :max_participants, :integer, null: false, default: 10
      add :settings, :map, default: %{}
      add :ended_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:watch_party_rooms, [:invite_code])
    create index(:watch_party_rooms, [:host_user_id])
    create index(:watch_party_rooms, [:status])

    # Partial index — only active rooms for invite lookups
    create index(:watch_party_rooms, [:invite_code],
      where: "status = 'active'",
      name: :watch_party_rooms_active_invite_idx
    )

    execute(
      "ALTER TABLE watch_party_rooms ADD CONSTRAINT watch_party_rooms_status_check CHECK (status IN ('active', 'ended'))",
      "ALTER TABLE watch_party_rooms DROP CONSTRAINT IF EXISTS watch_party_rooms_status_check"
    )

    # JSONB GIN for settings queries
    execute(
      "CREATE INDEX watch_party_rooms_settings_gin ON watch_party_rooms USING gin (settings jsonb_path_ops)",
      "DROP INDEX IF EXISTS watch_party_rooms_settings_gin"
    )

    create table(:watch_party_participants) do
      add :room_id, references(:watch_party_rooms, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "viewer"
      add :joined_at, :utc_datetime, null: false
      add :left_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:watch_party_participants, [:room_id])
    create index(:watch_party_participants, [:user_id])

    create unique_index(:watch_party_participants, [:room_id, :user_id],
      where: "left_at IS NULL",
      name: :watch_party_participants_active_unique
    )

    execute(
      "ALTER TABLE watch_party_participants ADD CONSTRAINT watch_party_participants_role_check CHECK (role IN ('host', 'viewer'))",
      "ALTER TABLE watch_party_participants DROP CONSTRAINT IF EXISTS watch_party_participants_role_check"
    )

    # Messages — TimescaleDB hypertable (append-only time-series chat)
    create table(:watch_party_messages, primary_key: false) do
      add :id, :bigserial
      add :room_id, :bigint, null: false
      add :user_id, :bigint, null: false
      add :content, :text, null: false
      add :type, :string, null: false, default: "text"

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    execute(
      "SELECT create_hypertable('watch_party_messages', 'inserted_at', chunk_time_interval => INTERVAL '1 day')",
      "SELECT 1"
    )

    create index(:watch_party_messages, [:room_id, :inserted_at])

    # Compress messages older than 7 days
    execute(
      """
      ALTER TABLE watch_party_messages SET (
        timescaledb.compress,
        timescaledb.compress_segmentby = 'room_id',
        timescaledb.compress_orderby = 'inserted_at DESC'
      )
      """,
      "ALTER TABLE watch_party_messages SET (timescaledb.compress = false)"
    )

    execute(
      "SELECT add_compression_policy('watch_party_messages', INTERVAL '7 days')",
      "SELECT remove_compression_policy('watch_party_messages', if_exists => true)"
    )

    # Drop messages older than 90 days
    execute(
      "SELECT add_retention_policy('watch_party_messages', INTERVAL '90 days')",
      "SELECT remove_retention_policy('watch_party_messages', if_exists => true)"
    )
  end
end
