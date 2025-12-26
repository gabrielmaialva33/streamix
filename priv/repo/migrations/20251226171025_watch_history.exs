defmodule Streamix.Repo.Migrations.WatchHistory do
  use Ecto.Migration

  def change do
    create table(:watch_history) do
      # "live_channel", "movie", "episode"
      add :content_type, :string, null: false
      add :content_id, :integer, null: false
      add :watched_at, :utc_datetime, null: false
      add :duration_seconds, :integer
      add :progress_seconds, :integer, default: 0
      add :completed, :boolean, default: false
      add :content_name, :text
      add :content_icon, :text
      # series name for episodes
      add :parent_name, :text
      # "S01E05" format
      add :episode_info, :string
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:watch_history, [:user_id])
    create index(:watch_history, [:user_id, :watched_at])
    create index(:watch_history, [:user_id, :content_type])
    create unique_index(:watch_history, [:user_id, :content_type, :content_id])
  end
end
