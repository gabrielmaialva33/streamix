defmodule Streamix.Repo.Migrations.CreateEpgPrograms do
  use Ecto.Migration

  def change do
    create table(:epg_programs, primary_key: false) do
      add :id, :bigserial
      add :epg_channel_id, :string, null: false
      add :title, :text, null: false
      add :description, :text
      add :start_time, :utc_datetime, null: false
      add :end_time, :utc_datetime, null: false
      add :category, :string
      add :icon, :text
      add :lang, :string, size: 10
      add :provider_id, :bigint, null: false

      timestamps(type: :utc_datetime)
    end

    # TimescaleDB hypertable — auto-partitions by start_time, 1-day chunks
    execute(
      "SELECT create_hypertable('epg_programs', 'start_time', chunk_time_interval => INTERVAL '1 day')",
      "SELECT 1"
    )

    # "What's on now" queries: provider + channel + time range
    create index(:epg_programs, [:provider_id, :start_time, :end_time])

    # Unique per provider+channel+start (includes partition column)
    create unique_index(:epg_programs, [:provider_id, :epg_channel_id, :start_time])

    # Compression — segment by provider+channel for efficient per-channel queries
    execute(
      """
      ALTER TABLE epg_programs SET (
        timescaledb.compress,
        timescaledb.compress_segmentby = 'provider_id, epg_channel_id',
        timescaledb.compress_orderby = 'start_time DESC'
      )
      """,
      "ALTER TABLE epg_programs SET (timescaledb.compress = false)"
    )

    # Auto-compress chunks older than 2 days
    execute(
      "SELECT add_compression_policy('epg_programs', INTERVAL '2 days')",
      "SELECT remove_compression_policy('epg_programs', if_exists => true)"
    )

    # Auto-drop EPG data older than 7 days
    execute(
      "SELECT add_retention_policy('epg_programs', INTERVAL '7 days')",
      "SELECT remove_retention_policy('epg_programs', if_exists => true)"
    )
  end
end
