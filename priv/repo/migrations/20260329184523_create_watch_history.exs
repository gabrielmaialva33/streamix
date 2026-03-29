defmodule Streamix.Repo.Migrations.CreateWatchHistory do
  use Ecto.Migration

  def change do
    create table(:watch_history) do
      add :content_type, :string, null: false
      add :content_id, :integer, null: false
      add :watched_at, :utc_datetime, null: false
      add :duration_seconds, :integer
      add :progress_seconds, :integer, default: 0
      add :completed, :boolean, default: false
      add :content_name, :text
      add :content_icon, :text
      add :parent_name, :text
      add :episode_info, :string
      add :ip_address, :string
      add :device_type, :string
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:watch_history, [:user_id])
    create index(:watch_history, [:user_id, :watched_at])
    create index(:watch_history, [:user_id, :content_type])
    create unique_index(:watch_history, [:user_id, :content_type, :content_id])
    create index(:watch_history, [:ip_address])

    # Partial index — "continue watching" feature (incomplete items only)
    create index(:watch_history, [:user_id, :watched_at],
             where: "completed = false AND progress_seconds > 0",
             name: :watch_history_continue_watching_idx
           )

    execute(
      "ALTER TABLE watch_history ADD CONSTRAINT watch_history_content_type_check CHECK (content_type IN ('live_channel', 'movie', 'episode'))",
      "ALTER TABLE watch_history DROP CONSTRAINT IF EXISTS watch_history_content_type_check"
    )
  end
end
