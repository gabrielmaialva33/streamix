defmodule Streamix.Repo.Migrations.CreateFavorites do
  use Ecto.Migration

  def change do
    create table(:favorites) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :live_channel_id, references(:live_channels, on_delete: :delete_all)
      add :movie_id, references(:movies, on_delete: :delete_all)
      add :series_id, references(:series, on_delete: :delete_all)
      add :episode_id, references(:episodes, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:favorites, [:user_id])

    create unique_index(:favorites, [:user_id, :live_channel_id],
             where: "live_channel_id IS NOT NULL",
             name: :favorites_user_live_channel_unique_idx
           )

    create unique_index(:favorites, [:user_id, :movie_id],
             where: "movie_id IS NOT NULL",
             name: :favorites_user_movie_unique_idx
           )

    create unique_index(:favorites, [:user_id, :series_id],
             where: "series_id IS NOT NULL",
             name: :favorites_user_series_unique_idx
           )

    create unique_index(:favorites, [:user_id, :episode_id],
             where: "episode_id IS NOT NULL",
             name: :favorites_user_episode_unique_idx
           )

    execute(
      """
      ALTER TABLE favorites
      ADD CONSTRAINT favorites_exactly_one_target_check
      CHECK (
        (CASE WHEN live_channel_id IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN movie_id IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN series_id IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN episode_id IS NOT NULL THEN 1 ELSE 0 END) = 1
      )
      """,
      "ALTER TABLE favorites DROP CONSTRAINT IF EXISTS favorites_exactly_one_target_check"
    )
  end
end
