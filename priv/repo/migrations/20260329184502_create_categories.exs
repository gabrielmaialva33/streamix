defmodule Streamix.Repo.Migrations.CreateCategories do
  use Ecto.Migration

  def change do
    create table(:categories) do
      add :external_id, :string, null: false
      add :name, :string, null: false
      add :type, :string, null: false
      add :is_adult, :boolean, default: false, null: false
      add :parent_id, references(:categories, on_delete: :nilify_all)
      add :provider_id, references(:providers, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:categories, [:provider_id, :type])
    create index(:categories, [:parent_id])
    create unique_index(:categories, [:provider_id, :external_id, :type])
    create index(:categories, [:provider_id, :is_adult])

    execute(
      "CREATE INDEX categories_name_trgm_idx ON categories USING gin (name gin_trgm_ops)",
      "DROP INDEX categories_name_trgm_idx"
    )

    execute(
      "ALTER TABLE categories ADD CONSTRAINT categories_type_check CHECK (type IN ('live', 'vod', 'series'))",
      "ALTER TABLE categories DROP CONSTRAINT IF EXISTS categories_type_check"
    )
  end
end
