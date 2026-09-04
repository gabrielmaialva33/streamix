defmodule Streamix.Repo.Migrations.WidenTmdbDetailsPendingIndex do
  use Ecto.Migration

  @pending """
  tmdb_details_at IS NULL AND tmdb_id IS NOT NULL \
  AND (plot IS NULL OR plot = '' OR title IS NULL OR title = '')\
  """

  # `TmdbDetailsWorker` now also picks up rows with a blank `title`, which are
  # displayed by their raw `name` — the release string, extension and all. The
  # index predicate has to match the query or it stops being usable at the tail,
  # which is the only place it matters.
  #
  # migration-safety: reviewed — this drops an index, never data, and the expand
  # and the contract are atomic: Ecto wraps the migration in a transaction, so
  # the replacement exists before the original goes. The new predicate is a
  # superset of the old one (same clauses, one more `OR`), so it also serves the
  # previous release's query during the window where migrations have run and the
  # new code has not started. `down/0` restores the original.
  def up do
    create index(:movies, [:id], where: @pending, name: :movies_tmdb_details_pending_idx)
    create index(:series, [:id], where: @pending, name: :series_tmdb_details_pending_idx)

    drop index(:movies, [:id], name: :movies_tmdb_details_pending_index)
    drop index(:series, [:id], name: :series_tmdb_details_pending_index)
  end

  def down do
    previous = "tmdb_details_at IS NULL AND tmdb_id IS NOT NULL AND (plot IS NULL OR plot = '')"

    create index(:movies, [:id], where: previous, name: :movies_tmdb_details_pending_index)
    create index(:series, [:id], where: previous, name: :series_tmdb_details_pending_index)

    drop index(:movies, [:id], name: :movies_tmdb_details_pending_idx)
    drop index(:series, [:id], name: :series_tmdb_details_pending_idx)
  end
end
