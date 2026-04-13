defmodule Streamix.Repo.Migrations.CreateFavorites do
  use Ecto.Migration

  def change do
    create table(:favorites, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), null: false, primary_key: true

      add :catalog_item_id, references(:catalog_items, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :inserted_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:favorites, [:catalog_item_id])
  end
end
