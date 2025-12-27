defmodule Streamix.Repo.Migrations.AddEpisodeExtendedMetadata do
  use Ecto.Migration

  def change do
    alter table(:episodes) do
      add :name, :string
      add :air_date, :date
      add :rating, :decimal
      add :still_path, :string
      add :tmdb_id, :integer
      add :tmdb_enriched, :boolean, default: false
    end
  end
end
