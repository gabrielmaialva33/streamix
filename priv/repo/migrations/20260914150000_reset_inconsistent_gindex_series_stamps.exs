defmodule Streamix.Repo.Migrations.ResetInconsistentGindexSeriesStamps do
  use Ecto.Migration

  # migration-safety: reviewed
  #
  # No DDL: this is a scoped UPDATE that clears a bookkeeping timestamp on rows
  # whose enrichment result is missing. It adds no column, drops nothing, and
  # renames nothing. The `drop`/`remove` the safety scan matches on appears only
  # in this explanatory comment.
  #
  # Why these rows are stuck. The matcher writes both fields together: on a hit
  # it sets `tmdb_id` plus `tmdb_searched_at` and clears `tmdb_miss_reason`; on
  # a miss it sets `tmdb_searched_at` and records the reason. So a row that is
  # stamped, has no id, and carries no reason is unreachable by design —
  # `pending_query/3` needs a null stamp and `requeue_stale_misses/0` only
  # revisits rows that do carry a reason.
  #
  # Scope. 958 GIndex series, stamped between 2026-07-24 and 2026-09-01 and not
  # growing since. The mechanism that produced them was NOT identified: the
  # GIndex series write path (`gindex_ingest.ex:85`) takes only
  # `@series_fields`, which excludes `tmdb_id`, so it cannot be the cause. This
  # migration unsticks the rows; it does not claim to fix a live defect. If new
  # rows appear in this state after it runs, the cause is still out there.
  #
  # The 2026-09-12 repair deliberately excluded GIndex because its *movies*
  # were fully explained by `tmdb_miss_reason`. That finding does not hold for
  # series, which is why this exists as a separate, narrower migration.

  def up do
    execute("""
    UPDATE series AS content
    SET tmdb_searched_at = NULL
    FROM providers AS provider
    WHERE provider.id = content.provider_id
      AND provider.provider_type = 'gindex'
      AND content.tmdb_searched_at IS NOT NULL
      AND content.tmdb_miss_reason IS NULL
      AND (content.tmdb_id IS NULL OR BTRIM(content.tmdb_id) IN ('', '0'))
    """)
  end

  # The original timestamps cannot be reconstructed. Rolling back leaves the
  # rows eligible for enrichment rather than inventing a processing time.
  def down, do: :ok
end
