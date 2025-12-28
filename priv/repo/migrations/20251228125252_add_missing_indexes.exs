defmodule Streamix.Repo.Migrations.AddMissingIndexes do
  use Ecto.Migration

  @doc """
  Adds missing indexes for better query performance.

  Indexes added:
  - favorites: compound index on (user_id, content_type) for filtering queries
  - watch_history: compound index on (user_id, content_type, watched_at DESC) for chronological queries
  - providers: index on (is_system, visibility, is_active) for public catalog queries
  """

  def change do
    # Favorites - compound index for filtering by type
    # Used in: Iptv.list_favorites(user_id, content_type: "movie")
    create_if_not_exists index(:favorites, [:user_id, :content_type])

    # Watch history - compound index for chronological queries
    # Used in: Iptv.list_watch_history(user_id, content_type: "movie")
    create_if_not_exists index(:watch_history, [:user_id, :content_type])

    # Watch history - index for recent items ordering
    create_if_not_exists index(:watch_history, [:user_id, :watched_at])

    # Providers - index for public catalog queries
    # Used in: Iptv.get_public_stats(), list_public_movies(), etc.
    create_if_not_exists index(:providers, [:is_system])
    create_if_not_exists index(:providers, [:visibility])
    create_if_not_exists index(:providers, [:is_active])
  end
end
