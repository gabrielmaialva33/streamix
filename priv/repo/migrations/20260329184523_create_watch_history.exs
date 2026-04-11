defmodule Streamix.Repo.Migrations.CreateWatchHistory do
  use Ecto.Migration

  def change do
    create table(:watch_history) do
      add :watched_at, :utc_datetime, null: false
      add :duration_seconds, :integer
      add :progress_seconds, :integer, default: 0
      add :completed, :boolean, default: false
      add :ip_address, :string
      add :device_type, :string
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :live_channel_id, references(:live_channels, on_delete: :delete_all)
      add :movie_id, references(:movies, on_delete: :delete_all)
      add :episode_id, references(:episodes, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:watch_history, [:user_id])
    create index(:watch_history, [:user_id, :watched_at])
    create index(:watch_history, [:ip_address])

    create unique_index(:watch_history, [:user_id, :live_channel_id],
             where: "live_channel_id IS NOT NULL",
             name: :watch_history_user_live_channel_unique_idx
           )

    create unique_index(:watch_history, [:user_id, :movie_id],
             where: "movie_id IS NOT NULL",
             name: :watch_history_user_movie_unique_idx
           )

    create unique_index(:watch_history, [:user_id, :episode_id],
             where: "episode_id IS NOT NULL",
             name: :watch_history_user_episode_unique_idx
           )

    # Partial index — "continue watching" feature (incomplete items only)
    create index(:watch_history, [:user_id, :watched_at],
             where: "completed = false AND progress_seconds > 0",
             name: :watch_history_continue_watching_idx
           )

    execute(
      """
      ALTER TABLE watch_history
      ADD CONSTRAINT watch_history_exactly_one_target_check
      CHECK (
        (CASE WHEN live_channel_id IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN movie_id IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN episode_id IS NOT NULL THEN 1 ELSE 0 END) = 1
      )
      """,
      "ALTER TABLE watch_history DROP CONSTRAINT IF EXISTS watch_history_exactly_one_target_check"
    )
  end
end
