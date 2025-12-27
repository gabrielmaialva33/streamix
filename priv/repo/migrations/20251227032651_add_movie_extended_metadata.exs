defmodule Streamix.Repo.Migrations.AddMovieExtendedMetadata do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :tagline, :string
      add :content_rating, :string
      add :images, {:array, :string}, default: []
    end
  end
end
