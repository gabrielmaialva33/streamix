defmodule Streamix.Repo.Migrations.CreateEpisodes do
  use Ecto.Migration

  def change do
    create table(:episodes) do
      add :episode_id, :integer, null: false
      add :episode_num, :integer, null: false
      add :title, :text
      add :name, :string
      add :plot, :text
      add :cover, :text
      add :duration_secs, :integer
      add :container_extension, :string
      add :air_date, :date
      add :rating, :decimal
      add :still_path, :string
      add :tmdb_id, :integer
      add :tmdb_enriched, :boolean, default: false
      add :gindex_path, :text
      add :gindex_url_cached, :text
      add :gindex_url_expires_at, :utc_datetime
      add :track_metadata, :jsonb
      add :season_id, references(:seasons, on_delete: :delete_all), null: false
      add :catalog_item_id, references(:catalog_items, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:episodes, [:season_id])
    create unique_index(:episodes, [:season_id, :episode_num])
    create unique_index(:episodes, [:season_id, :episode_id])
    create index(:episodes, [:gindex_path])
    create unique_index(:episodes, [:catalog_item_id])
  end
end
