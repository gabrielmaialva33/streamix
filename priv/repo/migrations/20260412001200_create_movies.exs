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
      add :plot, :text
      add :container_extension, :string
      add :duration_secs, :integer
      add :tmdb_id, :string
      add :imdb_id, :string
      add :youtube_trailer, :text
      add :tagline, :text
      add :content_rating, :string
      add :gindex_path, :text
      add :gindex_url_cached, :text
      add :gindex_url_expires_at, :utc_datetime
      add :tmdb_searched_at, :utc_datetime
      add :tmdb_miss_reason, :string
      add :track_metadata, :jsonb
      add :provider_id, references(:providers, on_delete: :delete_all), null: false
      add :catalog_item_id, :bigint, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:movies, [:provider_id])
    create unique_index(:movies, [:provider_id, :stream_id])
    create index(:movies, [:year])
    create index(:movies, [:rating])
    create index(:movies, [:gindex_path])
    create index(:movies, [:provider_id, :name])

    create index(:movies, [:tmdb_searched_at],
             where: "tmdb_searched_at IS NULL AND gindex_path IS NOT NULL",
             name: :movies_gindex_pending_enrichment_idx
           )

    execute(
      "CREATE INDEX movies_name_trgm_idx ON movies USING gin (name gin_trgm_ops)",
      "DROP INDEX movies_name_trgm_idx"
    )

    execute(
      "CREATE INDEX movies_title_trgm_idx ON movies USING gin (title gin_trgm_ops)",
      "DROP INDEX movies_title_trgm_idx"
    )

    create unique_index(:movies, [:catalog_item_id])
    create index(:movies, [:catalog_item_id, :provider_id])

    # Partial composite covering `list_public_movies` and any
    # `WHERE provider_id = X AND stream_icon IS NOT NULL ORDER BY rating`.
    # Without this, the planner falls back to a Parallel Seq Scan on the
    # whole movies table because none of the existing indexes encode the
    # `stream_icon IS NOT NULL` predicate together with the sort key.
    create index(:movies, [:provider_id, :rating],
             where: "stream_icon IS NOT NULL AND stream_icon <> ''",
             name: :movies_provider_id_rating_partial_idx
           )

    execute(
      """
      ALTER TABLE movies
        ADD CONSTRAINT movies_catalog_item_provider_fk
        FOREIGN KEY (catalog_item_id, provider_id)
        REFERENCES catalog_items (id, provider_id)
        ON DELETE CASCADE
      """,
      "ALTER TABLE movies DROP CONSTRAINT IF EXISTS movies_catalog_item_provider_fk"
    )
  end
end
