defmodule Streamix.Repo.Migrations.AddAnilistIdToSeries do
  use Ecto.Migration

  # AniList is used as a fallback enrichment source for anime rows that
  # TMDB couldn't match. We store the id in a separate column so code
  # that assumes `tmdb_id` corresponds to a real TMDB resource (e.g. the
  # xtream backfill worker that calls `TmdbClient.get_series/1`) doesn't
  # blow up on AniList-only rows.
  def change do
    alter table(:series) do
      add :anilist_id, :integer
    end

    create index(:series, [:anilist_id],
             where: "anilist_id IS NOT NULL",
             name: :series_anilist_id_idx
           )
  end
end
