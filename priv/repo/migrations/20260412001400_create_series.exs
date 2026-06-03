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
      add :plot, :text
      add :youtube_trailer, :text
      add :tmdb_id, :string
      add :anilist_id, :integer
      add :tomato_id, :integer
      add :dub_available, :boolean, default: false, null: false
      add :tagline, :text
      add :content_rating, :string
      add :gindex_path, :text
      add :tmdb_searched_at, :utc_datetime
      add :tmdb_miss_reason, :string
      add :provider_id, references(:providers, on_delete: :delete_all), null: false
      add :catalog_item_id, :bigint, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:series, [:provider_id])
    create unique_index(:series, [:provider_id, :series_id])
    create index(:series, [:year])
    create index(:series, [:rating])
    create index(:series, [:gindex_path])
    create index(:series, [:provider_id, :name])
    create unique_index(:series, [:catalog_item_id])
    create index(:series, [:catalog_item_id, :provider_id])

    create index(:series, [:anilist_id],
             where: "anilist_id IS NOT NULL",
             name: :series_anilist_id_idx
           )

    create index(:series, [:tomato_id],
             where: "tomato_id IS NOT NULL",
             name: :series_tomato_id_idx
           )

    create index(:series, [:tmdb_searched_at],
             where: "tmdb_searched_at IS NULL AND gindex_path IS NOT NULL",
             name: :series_gindex_pending_enrichment_idx
           )

    execute(
      "CREATE INDEX series_name_trgm_idx ON series USING gin (name gin_trgm_ops)",
      "DROP INDEX series_name_trgm_idx"
    )

    execute(
      "CREATE INDEX series_title_trgm_idx ON series USING gin (title gin_trgm_ops)",
      "DROP INDEX series_title_trgm_idx"
    )

    execute(
      """
      ALTER TABLE series
        ADD CONSTRAINT series_catalog_item_provider_fk
        FOREIGN KEY (catalog_item_id, provider_id)
        REFERENCES catalog_items (id, provider_id)
        ON DELETE CASCADE
      """,
      "ALTER TABLE series DROP CONSTRAINT IF EXISTS series_catalog_item_provider_fk"
    )
  end
end
