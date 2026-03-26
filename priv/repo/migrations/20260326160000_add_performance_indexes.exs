defmodule Streamix.Repo.Migrations.AddPerformanceIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # Batch lookups for watch history (home page loads progress for many items)
    create_if_not_exists index(:watch_history, [:user_id, :content_type, :content_id],
                           concurrently: true,
                           name: :watch_history_batch_lookup
                         )

    # Batch lookups for favorites
    create_if_not_exists index(:favorites, [:user_id, :content_type, :content_id],
                           concurrently: true,
                           name: :favorites_batch_lookup
                         )

    # Provider lookups for content tables
    create_if_not_exists index(:movies, [:provider_id, :name],
                           concurrently: true,
                           name: :movies_provider_name
                         )

    create_if_not_exists index(:series, [:provider_id, :name],
                           concurrently: true,
                           name: :series_provider_name
                         )

    create_if_not_exists index(:live_channels, [:provider_id, :name],
                           concurrently: true,
                           name: :live_channels_provider_name
                         )

    # Categories filtering
    create_if_not_exists index(:categories, [:provider_id, :is_adult],
                           concurrently: true,
                           name: :categories_provider_adult
                         )
  end
end
