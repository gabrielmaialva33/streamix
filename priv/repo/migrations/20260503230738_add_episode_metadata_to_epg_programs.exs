defmodule Streamix.Repo.Migrations.AddEpisodeMetadataToEpgPrograms do
  use Ecto.Migration

  # `epg_programs` is a TimescaleDB hypertable with compression policy.
  # ALTER TABLE ADD COLUMN on compressed hypertables is supported since
  # TimescaleDB 2.11 (we run pg17 + recent TS). Both columns are
  # nullable and have no default, so no rewrite of compressed chunks
  # is required — the new columns just expand the row schema going
  # forward and read as NULL on old rows.
  def change do
    alter table(:epg_programs) do
      add :sub_title, :string
      add :episode_num, :string
    end
  end
end
