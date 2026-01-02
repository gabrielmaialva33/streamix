defmodule Streamix.Repo.Migrations.AddIsAdultToCategories do
  use Ecto.Migration

  def change do
    alter table(:categories) do
      add :is_adult, :boolean, default: false, null: false
    end

    create index(:categories, [:is_adult])
  end
end
