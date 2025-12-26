defmodule Streamix.Repo.Migrations.MovieCategories do
  use Ecto.Migration

  def change do
    create table(:movie_categories, primary_key: false) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :category_id, references(:categories, on_delete: :delete_all), null: false
    end

    create unique_index(:movie_categories, [:movie_id, :category_id])
    create index(:movie_categories, [:category_id])
  end
end
