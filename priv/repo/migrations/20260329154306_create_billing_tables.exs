defmodule Streamix.Repo.Migrations.CreateBillingTables do
  use Ecto.Migration

  def change do
    create table(:plans) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :string
      add :price_cents, :integer, null: false
      add :currency, :string, null: false
      add :billing_interval, :string, null: false
      add :active, :boolean, null: false, default: true
      add :grants_global_access, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:plans, [:slug])

    create table(:subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :plan_id, references(:plans, on_delete: :restrict), null: false
      add :status, :string, null: false
      add :starts_at, :utc_datetime
      add :expires_at, :utc_datetime
      add :canceled_at, :utc_datetime
      add :source, :string
      add :external_reference, :string

      timestamps(type: :utc_datetime)
    end

    create index(:subscriptions, [:user_id])
    create index(:subscriptions, [:status])
  end
end
