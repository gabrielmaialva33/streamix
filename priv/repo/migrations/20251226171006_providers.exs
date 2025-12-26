defmodule Streamix.Repo.Migrations.Providers do
  use Ecto.Migration

  def change do
    create table(:providers) do
      add :name, :string, null: false
      add :url, :string, null: false
      add :username, :string, null: false
      add :password, :string, null: false
      add :is_active, :boolean, default: true, null: false
      add :sync_status, :string, default: "idle"

      # Contadores por tipo
      add :live_channels_count, :integer, default: 0
      add :movies_count, :integer, default: 0
      add :series_count, :integer, default: 0

      # Timestamps de sync por tipo
      add :live_synced_at, :utc_datetime
      add :vod_synced_at, :utc_datetime
      add :series_synced_at, :utc_datetime

      # Info do servidor (JSON)
      add :server_info, :map

      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:providers, [:user_id])
    create unique_index(:providers, [:user_id, :url, :username])
  end
end
