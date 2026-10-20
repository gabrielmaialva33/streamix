defmodule Streamix.Repo.Migrations.AddSlugAndPositionToGenres do
  use Ecto.Migration

  # Canonical genres carry a stable slug and their display order. Rows
  # without a slug are the raw provider names left from before the
  # vocabulary; `Streamix.Catalog.canonicalize_genres/0` remaps their links
  # and deletes them, so the column stays nullable until then.
  def change do
    alter table(:genres) do
      add :slug, :string
      add :position, :integer
    end

    create unique_index(:genres, [:slug])
  end
end
