defmodule Streamix.Repo.Migrations.AddContentAssetsUniqueIndex do
  use Ecto.Migration

  # Unique constraint lets the enrichment pipeline use
  # `on_conflict: :nothing` on Repo.insert_all instead of delete-then-insert,
  # saving one roundtrip per re-sync.
  def change do
    create unique_index(:movie_assets, [:movie_id, :asset_type, :url],
             name: :movie_assets_movie_id_type_url_index
           )

    create unique_index(:series_assets, [:series_id, :asset_type, :url],
             name: :series_assets_series_id_type_url_index
           )

    create unique_index(:episode_assets, [:episode_id, :asset_type, :url],
             name: :episode_assets_episode_id_type_url_index
           )
  end
end
