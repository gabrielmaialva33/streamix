defmodule Streamix.Repo.Migrations.Episodes do
  use Ecto.Migration

  def change do
    create table(:episodes) do
      add :episode_id, :integer, null: false
      add :episode_num, :integer, null: false
      add :title, :text
      add :plot, :text
      add :cover, :text
      add :duration_secs, :integer
      add :duration, :string
      add :container_extension, :string
      add :season_id, references(:seasons, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:episodes, [:season_id])
    create unique_index(:episodes, [:season_id, :episode_num])
    create unique_index(:episodes, [:season_id, :episode_id])
  end
end
