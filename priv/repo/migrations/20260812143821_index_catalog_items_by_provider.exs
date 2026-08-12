defmodule Streamix.Repo.Migrations.IndexCatalogItemsByProvider do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create index(:catalog_items, [:provider_id, :id],
             name: :catalog_items_provider_id_id_idx,
             include: [:content_type],
             concurrently: true
           )
  end
end
