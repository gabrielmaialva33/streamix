defmodule Streamix.Repo.Migrations.AddTmdbDetailsAtToSeasons do
  use Ecto.Migration

  # TMDB returns a whole season's episodes in one request, so the season — not
  # the episode — is the unit of work and the unit of bookkeeping. `episodes.
  # tmdb_enriched` cannot serve as the marker on its own: an episode number the
  # upstream carries but TMDB does not would leave the flag false forever and
  # put its season back in the queue every night.
  def change do
    alter table(:seasons) do
      add :tmdb_details_at, :utc_datetime
    end

    create index(:seasons, [:id],
             where: "tmdb_details_at IS NULL",
             name: :seasons_tmdb_details_pending_idx
           )
  end
end
