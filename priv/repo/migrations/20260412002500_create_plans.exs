defmodule Streamix.Repo.Migrations.CreatePlans do
  use Ecto.Migration

  def change do
    create table(:plans) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :string
      add :price_cents, :integer, null: false
      add :currency, :string, null: false
      add :billing_interval, :string, null: false
      add :stripe_price_id, :string
      add :trial_days, :integer, null: false, default: 0
      add :active, :boolean, null: false, default: true
      add :grants_global_access, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:plans, [:slug])
    create unique_index(:plans, [:stripe_price_id], where: "stripe_price_id IS NOT NULL")

    execute(
      "ALTER TABLE plans ADD CONSTRAINT plans_billing_interval_check CHECK (billing_interval IN ('day', 'week', 'month', 'year'))",
      "ALTER TABLE plans DROP CONSTRAINT IF EXISTS plans_billing_interval_check"
    )
  end
end
