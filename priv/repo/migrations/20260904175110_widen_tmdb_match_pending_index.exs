defmodule Streamix.Repo.Migrations.WidenTmdbMatchPendingIndex do
  use Ecto.Migration

  # `BackfillTmdbWorker` no longer restricts its sweep to gindex rows, so the
  # index backing its pending query has to lose the `gindex_path` half of its
  # predicate.
  #
  # migration-safety: reviewed — this drops an index, never data, and the
  # expand and the contract are already atomic here: Ecto wraps the migration
  # in a transaction, so the replacement exists before the original goes and
  # no query is ever left without one. The new predicate
  # (`tmdb_searched_at IS NULL`) is a strict superset of the old
  # (`... AND gindex_path IS NOT NULL`), so it serves every query the dropped
  # index served, including the previous release's — which matters because
  # migrations run before the new code is live. `down/0` recreates the
  # original, so the rollout is reversible in both directions.
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
