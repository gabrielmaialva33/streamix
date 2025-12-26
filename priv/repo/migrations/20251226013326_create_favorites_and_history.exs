defmodule Streamix.Repo.Migrations.CreateFavoritesAndHistory do
  use Ecto.Migration

  def change do
    create table(:favorites) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :channel_id, references(:channels, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:favorites, [:user_id, :channel_id])
    create index(:favorites, [:user_id])

    create table(:watch_history) do
      add :watched_at, :utc_datetime, null: false
      add :duration_seconds, :integer, default: 0
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :channel_id, references(:channels, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:watch_history, [:user_id])
    create index(:watch_history, [:user_id, :watched_at])
  end
end
