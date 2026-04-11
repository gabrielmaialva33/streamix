defmodule Streamix.Repo.Migrations.CreateProviders do
  use Ecto.Migration

  def change do
    create table(:providers) do
      add :name, :string, null: false
      add :url, :string, null: false
      add :username, :string
      add :password, :string
      add :is_active, :boolean, default: true, null: false
      add :sync_status, :string, default: "idle"
      add :visibility, :string, default: "private", null: false
      add :is_system, :boolean, default: false, null: false
      add :provider_type, :string, default: "xtream"

      # Sync counters
      add :live_channels_count, :integer, default: 0
      add :movies_count, :integer, default: 0
      add :series_count, :integer, default: 0

      # Sync timestamps
      add :live_synced_at, :utc_datetime
      add :vod_synced_at, :utc_datetime
      add :series_synced_at, :utc_datetime
      add :epg_synced_at, :utc_datetime
      add :epg_sync_interval_hours, :integer, default: 6

      # Server info and GIndex
      add :server_info, :map
      add :gindex_url, :string
      add :gindex_drives, :map

      add :user_id, references(:users, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:providers, [:user_id])
    create unique_index(:providers, [:user_id, :url, :username])
    create index(:providers, [:visibility, :is_system, :is_active])
    create index(:providers, [:provider_type])

    # Partial index — active public providers (catalog queries)
    create index(:providers, [:visibility, :is_system],
             where: "is_active = true",
             name: :providers_active_catalog_idx
           )

    # CHECK constraints
    execute(
      "ALTER TABLE providers ADD CONSTRAINT providers_visibility_check CHECK (visibility IN ('global', 'public', 'private'))",
      "ALTER TABLE providers DROP CONSTRAINT IF EXISTS providers_visibility_check"
    )

    execute(
      "ALTER TABLE providers ADD CONSTRAINT providers_provider_type_check CHECK (provider_type IN ('xtream', 'gindex'))",
      "ALTER TABLE providers DROP CONSTRAINT IF EXISTS providers_provider_type_check"
    )

    # JSONB GIN indexes — query JSON fields without full table scan
    execute(
      "CREATE INDEX providers_server_info_gin ON providers USING gin (server_info jsonb_path_ops)",
      "DROP INDEX IF EXISTS providers_server_info_gin"
    )

    execute(
      "CREATE INDEX providers_gindex_drives_gin ON providers USING gin (gindex_drives jsonb_path_ops)",
      "DROP INDEX IF EXISTS providers_gindex_drives_gin"
    )
  end
end
