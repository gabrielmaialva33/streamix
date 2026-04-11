defmodule Streamix.Repo.Migrations.CreateAccessLogs do
  use Ecto.Migration

  def change do
    # No PK — TimescaleDB hypertable requires time column in unique constraints
    create table(:access_logs, primary_key: false) do
      add :id, :bigserial
      add :user_id, references(:users, on_delete: :nilify_all)
      add :ip_address, :string, null: false
      add :user_agent, :text
      add :path, :string
      add :method, :string
      add :country, :string
      add :city, :string
      add :device_type, :string
      add :browser, :string
      add :os, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # TimescaleDB hypertable — auto-partitions by time chunks
    execute(
      "SELECT create_hypertable('access_logs', 'inserted_at')",
      "SELECT 1"
    )

    create index(:access_logs, [:id])
    create index(:access_logs, [:user_id])
    create index(:access_logs, [:ip_address])

    # Native compression — segmentby keeps per-user queries fast
    execute(
      """
      ALTER TABLE access_logs SET (
        timescaledb.compress,
        timescaledb.compress_segmentby = 'user_id',
        timescaledb.compress_orderby = 'inserted_at DESC'
      )
      """,
      "ALTER TABLE access_logs SET (timescaledb.compress = false)"
    )

    # Auto-compress chunks older than 7 days
    execute(
      "SELECT add_compression_policy('access_logs', INTERVAL '7 days')",
      "SELECT remove_compression_policy('access_logs', if_exists => true)"
    )

    # Auto-drop data older than 90 days
    execute(
      "SELECT add_retention_policy('access_logs', INTERVAL '90 days')",
      "SELECT remove_retention_policy('access_logs', if_exists => true)"
    )
  end
end
