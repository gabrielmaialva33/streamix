defmodule Streamix.Repo.Migrations.IndexCatalogItemsByContentType do
  use Ecto.Migration

  # Supports planner-friendly per-content_type anti-joins in
  # Streamix.Iptv.Sync.Cleanup without scanning unrelated content types or
  # sorting by id.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:catalog_items, [:provider_id, :content_type, :id],
             name: :catalog_items_provider_id_content_type_id_idx,
             concurrently: true
           )

    create index(:catalog_items, [:content_type, :id],
             name: :catalog_items_content_type_id_idx,
             concurrently: true
           )
  end
end
