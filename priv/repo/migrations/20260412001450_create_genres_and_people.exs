defmodule Streamix.Repo.Migrations.CreateGenresAndPeople do
  use Ecto.Migration

  def change do
    create table(:genres) do
      add :name, :citext, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:genres, [:name])

    execute(
      "CREATE INDEX genres_name_trgm_idx ON genres USING gin (name gin_trgm_ops)",
      "DROP INDEX genres_name_trgm_idx"
    )

    create table(:people) do
      add :name, :citext, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:people, [:name])

    execute(
      "CREATE INDEX people_name_trgm_idx ON people USING gin (name gin_trgm_ops)",
      "DROP INDEX people_name_trgm_idx"
    )

    # Movie junction tables
    create table(:movie_genres, primary_key: false) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false, primary_key: true
      add :genre_id, references(:genres, on_delete: :delete_all), null: false, primary_key: true
    end

    create index(:movie_genres, [:genre_id])

    create table(:movie_credits) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :person_id, references(:people, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :position, :integer, default: 0
    end

    create unique_index(:movie_credits, [:movie_id, :person_id, :role])
    create index(:movie_credits, [:person_id])

    execute(
      "ALTER TABLE movie_credits ADD CONSTRAINT movie_credits_role_check CHECK (role IN ('cast', 'director', 'writer', 'producer'))",
      "ALTER TABLE movie_credits DROP CONSTRAINT IF EXISTS movie_credits_role_check"
    )

    # Series junction tables
    create table(:series_genres, primary_key: false) do
      add :series_id, references(:series, on_delete: :delete_all), null: false, primary_key: true
      add :genre_id, references(:genres, on_delete: :delete_all), null: false, primary_key: true
    end

    create index(:series_genres, [:genre_id])

    create table(:series_credits) do
      add :series_id, references(:series, on_delete: :delete_all), null: false
      add :person_id, references(:people, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :position, :integer, default: 0
    end

    create unique_index(:series_credits, [:series_id, :person_id, :role])
    create index(:series_credits, [:person_id])

    execute(
      "ALTER TABLE series_credits ADD CONSTRAINT series_credits_role_check CHECK (role IN ('cast', 'director', 'writer', 'producer'))",
      "ALTER TABLE series_credits DROP CONSTRAINT IF EXISTS series_credits_role_check"
    )
  end
end
