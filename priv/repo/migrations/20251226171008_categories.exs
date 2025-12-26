defmodule Streamix.Repo.Migrations.Categories do
  use Ecto.Migration

  def change do
    create table(:categories) do
      add :external_id, :string, null: false
      add :name, :string, null: false
      # "live", "vod", "series"
      add :type, :string, null: false
      add :parent_id, references(:categories, on_delete: :nilify_all)
      add :provider_id, references(:providers, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:categories, [:provider_id])
    create index(:categories, [:provider_id, :type])
    create index(:categories, [:parent_id])
    create unique_index(:categories, [:provider_id, :external_id, :type])
  end
end
