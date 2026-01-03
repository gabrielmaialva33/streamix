defmodule Streamix.Repo.Migrations.AddContentTypeToSeries do
  use Ecto.Migration

  def change do
    alter table(:series) do
      add :content_type, :string, default: "series"
    end

    create index(:series, [:content_type])
  end
end
