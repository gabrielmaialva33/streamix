defmodule Streamix.Repo.Migrations.CreatePlanFeatures do
  use Ecto.Migration

  def change do
    create table(:plan_features) do
      add :plan_id, references(:plans, on_delete: :delete_all), null: false
      add :feature, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :limit, :integer
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:plan_features, [:plan_id, :feature])
    create index(:plan_features, [:feature])
  end
end
