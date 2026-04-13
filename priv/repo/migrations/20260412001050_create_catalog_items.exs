defmodule Streamix.Repo.Migrations.CreateCatalogItems do
  use Ecto.Migration

  def change do
    create table(:catalog_items) do
      add :content_type, :string, null: false
      add :provider_id, references(:providers, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:catalog_items, [:content_type])
    create index(:catalog_items, [:provider_id])
    create unique_index(:catalog_items, [:id, :provider_id])

    execute(
      "ALTER TABLE catalog_items ADD CONSTRAINT catalog_items_content_type_check CHECK (content_type IN ('live_channel', 'movie', 'series', 'episode'))",
      "ALTER TABLE catalog_items DROP CONSTRAINT IF EXISTS catalog_items_content_type_check"
    )
  end
end
