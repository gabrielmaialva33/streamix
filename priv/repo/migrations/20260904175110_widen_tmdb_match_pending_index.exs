defmodule Streamix.Repo.Migrations.WidenTmdbMatchPendingIndex do
  use Ecto.Migration

  # `BackfillTmdbWorker` no longer restricts its sweep to gindex rows, so the
  # index backing its pending query has to lose the `gindex_path` half of its
  # predicate. The new predicate is a superset of the old one — everything the
  # gindex-scoped index served, this one serves too — so the old index is
  # dropped rather than kept alongside.
  def up do
    create index(:movies, [:id],
             where: "tmdb_searched_at IS NULL",
             name: :movies_tmdb_match_pending_idx
           )

    create index(:series, [:id],
             where: "tmdb_searched_at IS NULL",
             name: :series_tmdb_match_pending_idx
           )

    drop index(:movies, [:tmdb_searched_at], name: :movies_gindex_pending_enrichment_idx)
    drop index(:series, [:tmdb_searched_at], name: :series_gindex_pending_enrichment_idx)
  end

  def down do
    create index(:movies, [:tmdb_searched_at],
             where: "tmdb_searched_at IS NULL AND gindex_path IS NOT NULL",
             name: :movies_gindex_pending_enrichment_idx
           )

    create index(:series, [:tmdb_searched_at],
             where: "tmdb_searched_at IS NULL AND gindex_path IS NOT NULL",
             name: :series_gindex_pending_enrichment_idx
           )

    drop index(:movies, [:id], name: :movies_tmdb_match_pending_idx)
    drop index(:series, [:id], name: :series_tmdb_match_pending_idx)
  end
end
