defmodule Streamix.Repo.Migrations.CreateStations do
  use Ecto.Migration

  # A station is a 24h channel made from the catalog: a discovery query
  # ("terror anos 80") turned into a looping program of movies. What plays
  # now is pure arithmetic on `program_started_at` and the program's
  # durations, so every viewer sees the same minute.
  def change do
    create table(:stations) do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :description, :string
      add :query, :string, null: false
      add :position, :integer, null: false, default: 0
      add :active, :boolean, null: false, default: true
      add :program, {:array, :map}, null: false, default: []
      add :program_started_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:stations, [:slug])
  end
end
