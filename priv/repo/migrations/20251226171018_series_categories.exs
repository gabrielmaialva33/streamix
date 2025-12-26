defmodule Streamix.Repo.Migrations.SeriesCategories do
  use Ecto.Migration

  def change do
    create table(:series_categories, primary_key: false) do
      add :series_id, references(:series, on_delete: :delete_all), null: false
      add :category_id, references(:categories, on_delete: :delete_all), null: false
    end

    create unique_index(:series_categories, [:series_id, :category_id])
    create index(:series_categories, [:category_id])
  end
end
