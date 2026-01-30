defmodule Streamix.Repo.Migrations.AddIpTracking do
  use Ecto.Migration

  def change do
    # 1. Add IP to users_tokens (login tracking)
    alter table(:users_tokens) do
      add :ip_address, :string
      add :user_agent, :text
      add :country, :string
      add :city, :string
    end

    # 2. Create access_logs table
    create table(:access_logs) do
      add :user_id, references(:users, on_delete: :delete_all)
      add :ip_address, :string, null: false
      add :user_agent, :text
      add :path, :string
      add :method, :string
      add :country, :string
      add :city, :string
      add :device_type, :string  # mobile, desktop, tablet, tv
      add :browser, :string
      add :os, :string

      timestamps(updated_at: false)
    end

    create index(:access_logs, [:user_id])
    create index(:access_logs, [:ip_address])
    create index(:access_logs, [:inserted_at])

    # 3. Add IP to watch_history
    alter table(:watch_history) do
      add :ip_address, :string
      add :device_type, :string
    end

    create index(:watch_history, [:ip_address])
  end
end
