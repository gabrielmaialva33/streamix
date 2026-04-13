defmodule Streamix.Repo.Migrations.CreateWatchProgressAndEvents do
  use Ecto.Migration

  def change do
    create table(:watch_progress) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :catalog_item_id, references(:catalog_items, on_delete: :delete_all), null: false
      add :progress_seconds, :integer, null: false, default: 0
      add :duration_seconds, :integer
      add :completed, :boolean, null: false, default: false
      add :last_watched_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:watch_progress, [:user_id, :catalog_item_id])
    create index(:watch_progress, [:catalog_item_id])

    # Partial index for "continue watching" feature
    create index(:watch_progress, [:user_id, :last_watched_at],
             where: "completed = false AND progress_seconds > 0",
             name: :watch_progress_continue_watching_idx
           )

    create table(:watch_events) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :catalog_item_id, references(:catalog_items, on_delete: :delete_all), null: false
      add :watched_at, :utc_datetime, null: false
      add :session_seconds, :integer
      add :progress_seconds, :integer
      add :completed, :boolean, null: false, default: false
      add :ip_address, :inet
      add :device_type, :string

      add :inserted_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:watch_events, [:user_id, :watched_at])
    create index(:watch_events, [:catalog_item_id])
  end
end
