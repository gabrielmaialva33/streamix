defmodule Streamix.Repo.Migrations.AddSeriesToStations do
  use Ecto.Migration

  # A station plays either movies found by its discovery `query` or random
  # episodes of the series listed by TMDB id ("Chaves 24h", a sitcom
  # marathon). Existing stations are movie stations.
  def change do
    alter table(:stations) do
      add :kind, :string, null: false, default: "movies"
      add :series_tmdb_ids, {:array, :string}, null: false, default: []
    end
  end
end
