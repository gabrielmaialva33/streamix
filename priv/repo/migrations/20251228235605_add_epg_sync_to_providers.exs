defmodule Streamix.Repo.Migrations.AddEpgSyncToProviders do
  use Ecto.Migration

  def change do
    alter table(:providers) do
      add :epg_synced_at, :utc_datetime
      add :epg_sync_interval_hours, :integer, default: 6
    end
  end
end
