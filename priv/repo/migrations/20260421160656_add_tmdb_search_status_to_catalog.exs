defmodule Streamix.Repo.Migrations.AddTmdbSearchStatusToCatalog do
  use Ecto.Migration

  # Adds idempotency columns so the gindex TMDB enricher can skip rows
  # it has already tried. Without these we'd re-query TMDB for every
  # catalog row on every nightly pass, wasting the per-token rate budget
  # on titles that are genuinely not on TMDB (obscure brazilian releases,
  # fan-edits, etc).
  def change do
    alter table(:movies) do
      add :tmdb_searched_at, :utc_datetime
      add :tmdb_miss_reason, :string
    end

    alter table(:series) do
      add :tmdb_searched_at, :utc_datetime
      add :tmdb_miss_reason, :string
    end

    # Partial index so the enricher's "pending" query stays fast even
    # when >95% of rows have already been processed.
    create index(:movies, [:tmdb_searched_at],
             where: "tmdb_searched_at IS NULL AND gindex_path IS NOT NULL",
             name: :movies_gindex_pending_enrichment_idx
           )

    create index(:series, [:tmdb_searched_at],
             where: "tmdb_searched_at IS NULL AND gindex_path IS NOT NULL",
             name: :series_gindex_pending_enrichment_idx
           )
  end
end
