defmodule Streamix.Repo.Migrations.CreateContentAssets do
  use Ecto.Migration

  def change do
    create table(:movie_assets) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :asset_type, :string, null: false
      add :url, :text, null: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:movie_assets, [:movie_id])

    create unique_index(:movie_assets, [:movie_id, :asset_type, :url],
             name: :movie_assets_movie_id_type_url_index
           )

    execute(
      "ALTER TABLE movie_assets ADD CONSTRAINT movie_assets_type_check CHECK (asset_type IN ('poster', 'backdrop', 'image', 'icon'))",
      "ALTER TABLE movie_assets DROP CONSTRAINT IF EXISTS movie_assets_type_check"
    )

    create table(:series_assets) do
      add :series_id, references(:series, on_delete: :delete_all), null: false
      add :asset_type, :string, null: false
      add :url, :text, null: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:series_assets, [:series_id])

    create unique_index(:series_assets, [:series_id, :asset_type, :url],
             name: :series_assets_series_id_type_url_index
           )

    execute(
      "ALTER TABLE series_assets ADD CONSTRAINT series_assets_type_check CHECK (asset_type IN ('poster', 'backdrop', 'image', 'cover'))",
      "ALTER TABLE series_assets DROP CONSTRAINT IF EXISTS series_assets_type_check"
    )

    create table(:episode_assets) do
      add :episode_id, references(:episodes, on_delete: :delete_all), null: false
      add :asset_type, :string, null: false
      add :url, :text, null: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:episode_assets, [:episode_id])

    create unique_index(:episode_assets, [:episode_id, :asset_type, :url],
             name: :episode_assets_episode_id_type_url_index
           )

    execute(
      "ALTER TABLE episode_assets ADD CONSTRAINT episode_assets_type_check CHECK (asset_type IN ('cover', 'still'))",
      "ALTER TABLE episode_assets DROP CONSTRAINT IF EXISTS episode_assets_type_check"
    )
  end
end
