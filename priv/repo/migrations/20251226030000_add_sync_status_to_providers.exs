defmodule Streamix.Repo.Migrations.AddSyncStatusToProviders do
  use Ecto.Migration

  def change do
    alter table(:providers) do
      add :sync_status, :string, default: "idle"
    end
  end
end
