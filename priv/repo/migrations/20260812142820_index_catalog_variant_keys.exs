defmodule Streamix.Repo.Migrations.IndexCatalogVariantKeys do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    create index(:movies, [:variant_key, desc: :id],
             name: :movies_variant_key_id_idx,
             include: [:provider_id, :catalog_item_id],
             concurrently: true
           )

    create index(:series, [:variant_key, desc: :id],
             name: :series_variant_key_id_idx,
             include: [:provider_id, :catalog_item_id],
             concurrently: true
           )

    # The generated columns are new, so collect cardinality before the first
    # catalog request can inherit PostgreSQL's generic 200-group estimate.
    execute("ANALYZE movies")
    execute("ANALYZE series")
  end

  # migration-safety: reviewed — rollback concurrently removes only non-unique
  # read-optimization indexes; it removes no catalog data, columns, or constraints.
  def down do
    drop index(:series, [], name: :series_variant_key_id_idx, concurrently: true)
    drop index(:movies, [], name: :movies_variant_key_id_idx, concurrently: true)
  end
end
