defmodule Streamix.Repo.Migrations.AddGindexFieldsToSeriesAndEpisodes do
  use Ecto.Migration

  def change do
    # Add gindex fields to series
    alter table(:series) do
      add :gindex_path, :string
    end

    # Add gindex fields to episodes
    alter table(:episodes) do
      add :gindex_path, :string
      add :gindex_url_cached, :string
      add :gindex_url_expires_at, :utc_datetime
    end

    # Create indexes for gindex_path queries
    create index(:series, [:gindex_path])
    create index(:episodes, [:gindex_path])
  end
end
