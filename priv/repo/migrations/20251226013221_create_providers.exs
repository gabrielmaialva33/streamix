defmodule Streamix.Repo.Migrations.CreateProviders do
  use Ecto.Migration

  def change do
    create table(:providers) do
      add :name, :string, null: false
      add :url, :string, null: false
      add :username, :string, null: false
      add :password, :string, null: false
      add :is_active, :boolean, default: true
      add :last_synced_at, :utc_datetime
      add :channels_count, :integer, default: 0
      add :sync_status, :string, default: "idle"
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:providers, [:user_id])
    create index(:providers, [:user_id, :is_active])
    create unique_index(:providers, [:user_id, :url, :username])
  end
end
