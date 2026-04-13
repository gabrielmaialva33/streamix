defmodule Streamix.Repo.Migrations.CreateItemCategories do
  use Ecto.Migration

  def change do
    create table(:item_categories, primary_key: false) do
      add :catalog_item_id, references(:catalog_items, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :category_id, references(:categories, on_delete: :delete_all),
        null: false,
        primary_key: true
    end

    create index(:item_categories, [:category_id])
  end
end
