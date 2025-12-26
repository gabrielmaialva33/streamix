defmodule Streamix.Repo.Migrations.Movies do
  use Ecto.Migration

  def change do
    create table(:movies) do
      add :stream_id, :integer, null: false
      add :name, :text, null: false
      add :title, :text
      add :year, :integer
      add :stream_icon, :text
      add :rating, :decimal
      add :rating_5based, :decimal
      add :genre, :text
      add :cast, :text
      add :director, :text
      add :plot, :text
      add :container_extension, :string
      add :duration_secs, :integer
      add :duration, :string
      add :tmdb_id, :string
      add :imdb_id, :string
      add :backdrop_path, {:array, :text}
      add :youtube_trailer, :string
      add :provider_id, references(:providers, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:movies, [:provider_id])
    create unique_index(:movies, [:provider_id, :stream_id])
    create index(:movies, [:year])
    create index(:movies, [:rating])

    execute(
      "CREATE INDEX movies_name_trgm_idx ON movies USING gin (name gin_trgm_ops)",
      "DROP INDEX movies_name_trgm_idx"
    )
  end
end
