defmodule Streamix.Repo.Migrations.CreateMovies do
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
      add :youtube_trailer, :text
      add :tagline, :text
      add :content_rating, :string
      add :images, {:array, :string}, default: []
      add :gindex_path, :text
      add :gindex_url_cached, :text
      add :gindex_url_expires_at, :utc_datetime
      add :provider_id, references(:providers, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:movies, [:provider_id])
    create unique_index(:movies, [:provider_id, :stream_id])
    create index(:movies, [:year])
    create index(:movies, [:rating])
    create index(:movies, [:gindex_path])
    create index(:movies, [:provider_id, :name])

    execute(
      "CREATE INDEX movies_name_trgm_idx ON movies USING gin (name gin_trgm_ops)",
      "DROP INDEX movies_name_trgm_idx"
    )

    execute(
      "CREATE INDEX movies_title_trgm_idx ON movies USING gin (title gin_trgm_ops)",
      "DROP INDEX movies_title_trgm_idx"
    )

    execute(
      "CREATE INDEX movies_genre_trgm_idx ON movies USING gin (genre gin_trgm_ops)",
      "DROP INDEX movies_genre_trgm_idx"
    )

    # Junction table
    create table(:movie_categories, primary_key: false) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :category_id, references(:categories, on_delete: :delete_all), null: false
    end

    create unique_index(:movie_categories, [:movie_id, :category_id])
    create index(:movie_categories, [:category_id])
  end
end
