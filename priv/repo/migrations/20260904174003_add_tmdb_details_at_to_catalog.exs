defmodule Streamix.Repo.Migrations.AddTmdbDetailsAtToCatalog do
  use Ecto.Migration

  # `tmdb_searched_at` records that we looked for a *match*; it says nothing
  # about whether the matched record's details were ever read. The gindex
  # poster backfill stamps it after writing only `poster_path` + `tmdb_id`,
  # which is why ~14.5k movies carry a tmdb_id and no synopsis.
  #
  # This column is the marker for the second half: details were fetched.
  # Without it, "plot is still empty" is the only idempotency signal, and a
  # title TMDB has no pt-BR overview for would be re-fetched on every run,
  # forever.
  def change do
    alter table(:movies) do
      add :tmdb_details_at, :utc_datetime
    end

    alter table(:series) do
      add :tmdb_details_at, :utc_datetime
    end

    # Partial index over exactly the worker's selection. The predicate is
    # mutable on purpose: a row drops out of the index as soon as it is
    # enriched, so the index shrinks to nothing as the backlog drains.
    create index(:movies, [:id],
             where:
               "tmdb_details_at IS NULL AND tmdb_id IS NOT NULL AND (plot IS NULL OR plot = '')",
             name: :movies_tmdb_details_pending_index
           )

    create index(:series, [:id],
             where:
               "tmdb_details_at IS NULL AND tmdb_id IS NOT NULL AND (plot IS NULL OR plot = '')",
             name: :series_tmdb_details_pending_index
           )
  end
end
