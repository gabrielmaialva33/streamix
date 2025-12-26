defmodule Streamix.Repo.Migrations.Seasons do
  use Ecto.Migration

  def change do
    create table(:seasons) do
      add :season_number, :integer, null: false
      add :name, :string
      add :cover, :text
      add :air_date, :date
      add :overview, :text
      add :episode_count, :integer, default: 0
      add :series_id, references(:series, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:seasons, [:series_id])
    create unique_index(:seasons, [:series_id, :season_number])
  end
end
