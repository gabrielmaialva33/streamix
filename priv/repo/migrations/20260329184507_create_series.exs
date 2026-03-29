defmodule Streamix.Repo.Migrations.CreateSeries do
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
      add :youtube_trailer, :text
      add :tmdb_id, :string
      add :season_count, :integer, default: 0
      add :episode_count, :integer, default: 0
      add :tagline, :text
      add :content_rating, :string
      add :images, {:array, :string}, default: []
      add :gindex_path, :text
      add :content_type, :string, default: "series"
      add :provider_id, references(:providers, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:series, [:provider_id])
    create unique_index(:series, [:provider_id, :series_id])
    create index(:series, [:year])
    create index(:series, [:rating])
    create index(:series, [:gindex_path])
    create index(:series, [:content_type])
    create index(:series, [:provider_id, :name])

    execute(
      "CREATE INDEX series_name_trgm_idx ON series USING gin (name gin_trgm_ops)",
      "DROP INDEX series_name_trgm_idx"
    )

    execute(
      "CREATE INDEX series_title_trgm_idx ON series USING gin (title gin_trgm_ops)",
      "DROP INDEX series_title_trgm_idx"
    )

    # Junction table
    create table(:series_categories, primary_key: false) do
      add :series_id, references(:series, on_delete: :delete_all), null: false
      add :category_id, references(:categories, on_delete: :delete_all), null: false
    end

    create unique_index(:series_categories, [:series_id, :category_id])
    create index(:series_categories, [:category_id])
  end
end
