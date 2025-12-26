defmodule Streamix.Repo.Migrations.CreateChannels do
  use Ecto.Migration

  def change do
    execute(
      "CREATE EXTENSION IF NOT EXISTS pg_trgm",
      "DROP EXTENSION IF EXISTS pg_trgm"
    )

    create table(:channels) do
      add :name, :text, null: false
      add :logo_url, :text
      add :stream_url, :text, null: false
      add :tvg_id, :text
      add :tvg_name, :text
      add :group_title, :text
      add :provider_id, references(:providers, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:channels, [:provider_id])

    # Expression-based indexes to avoid "index row size exceeds maximum" error
    # Truncate long text fields to 255 chars for indexing
    execute(
      """
      CREATE INDEX channels_provider_group_name_idx
      ON channels (provider_id, LEFT(group_title, 100), LEFT(name, 100))
      """,
      "DROP INDEX IF EXISTS channels_provider_group_name_idx"
    )

    execute(
      """
      CREATE INDEX channels_group_title_idx
      ON channels (LEFT(group_title, 100))
      WHERE group_title IS NOT NULL
      """,
      "DROP INDEX IF EXISTS channels_group_title_idx"
    )

    execute(
      """
      CREATE INDEX channels_name_trgm_idx
      ON channels USING gin (LEFT(name, 255) gin_trgm_ops)
      """,
      "DROP INDEX IF EXISTS channels_name_trgm_idx"
    )
  end
end
