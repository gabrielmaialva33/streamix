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

    # Partial indexes for public content (90%+ of queries filter by visibility)
    create_if_not_exists index(:movies, [:provider_id],
                           concurrently: true,
                           where: "visibility IN ('public', 'global')",
                           name: :movies_public_visibility
                         )

    create_if_not_exists index(:series, [:provider_id],
                           concurrently: true,
                           where: "visibility IN ('public', 'global')",
                           name: :series_public_visibility
                         )

    create_if_not_exists index(:live_channels, [:provider_id],
                           concurrently: true,
                           where: "visibility IN ('public', 'global')",
                           name: :live_channels_public_visibility
                         )

    # Categories filtering
    create_if_not_exists index(:categories, [:provider_id, :is_adult],
                           concurrently: true,
                           name: :categories_provider_adult
                         )
  end
end
