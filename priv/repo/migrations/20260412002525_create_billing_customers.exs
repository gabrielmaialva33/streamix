defmodule Streamix.Repo.Migrations.CreateBillingCustomers do
  use Ecto.Migration

  def change do
    create table(:billing_customers) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :external_id, :string, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:billing_customers, [:user_id])
    create unique_index(:billing_customers, [:provider, :external_id])
    create unique_index(:billing_customers, [:user_id, :provider])
  end
end
