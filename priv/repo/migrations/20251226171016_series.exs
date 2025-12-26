defmodule Streamix.Repo.Migrations.Series do
  use Ecto.Migration

  def change do
    create table(:series) do
      add :series_id, :integer, null: false
      add :name, :text, null: false
      add :title, :text
      add :year, :integer
      add :cover, :text
      add :rating, :decimal
      add :rating_5based, :decimal
      add :genre, :text
      add :cast, :text
      add :director, :text
      add :plot, :text
      add :backdrop_path, {:array, :text}
      add :youtube_trailer, :string
      add :tmdb_id, :string
      add :season_count, :integer, default: 0
      add :episode_count, :integer, default: 0
      add :provider_id, references(:providers, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:series, [:provider_id])
    create unique_index(:series, [:provider_id, :series_id])
    create index(:series, [:year])
    create index(:series, [:rating])

    execute(
      "CREATE INDEX series_name_trgm_idx ON series USING gin (name gin_trgm_ops)",
      "DROP INDEX series_name_trgm_idx"
    )
  end
end
