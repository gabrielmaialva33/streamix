defmodule Streamix.Repo.Migrations.AddSeriesExtendedMetadata do
  use Ecto.Migration

  def change do
    alter table(:series) do
      add :tagline, :string
      add :content_rating, :string
      add :images, {:array, :string}, default: []
    end
  end
end
