defmodule Streamix.Repo.Migrations.CreateCatalogItems do
  use Ecto.Migration

  def change do
    create table(:catalog_items) do
      add :content_type, :string, null: false
      add :provider_id, references(:providers, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    # `(id, content_type)` lets trending / favorites joins answer the
    # `content_type = 'movie'` predicate without an extra Filter step
    # after the `(id, provider_id)` index scan. The standalone
    # `[:content_type]` and `[:provider_id]` indexes were never picked
    # by the planner in prod (idx_scan = 0) — both removed.
    create index(:catalog_items, [:id, :content_type])
    create unique_index(:catalog_items, [:id, :provider_id])

    execute(
      "ALTER TABLE catalog_items ADD CONSTRAINT catalog_items_content_type_check CHECK (content_type IN ('live_channel', 'movie', 'series', 'episode'))",
      "ALTER TABLE catalog_items DROP CONSTRAINT IF EXISTS catalog_items_content_type_check"
    )
  end
end
