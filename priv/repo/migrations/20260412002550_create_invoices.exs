defmodule Streamix.Repo.Migrations.CreateInvoices do
  use Ecto.Migration

  def change do
    create table(:invoices) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :plan_id, references(:plans, on_delete: :restrict), null: false
      add :subscription_id, references(:subscriptions, on_delete: :nilify_all)
      add :provider, :string, null: false
      add :status, :string, null: false
      add :external_id, :string
      add :number, :string
      add :amount_due_cents, :integer, null: false
      add :amount_paid_cents, :integer, null: false, default: 0
      add :currency, :string, null: false
      add :hosted_invoice_url, :string
      add :due_at, :utc_datetime
      add :paid_at, :utc_datetime
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:invoices, [:user_id])
    create index(:invoices, [:plan_id])
    create index(:invoices, [:subscription_id])
    create index(:invoices, [:status])
    create unique_index(:invoices, [:provider, :external_id], where: "external_id IS NOT NULL")

    execute(
      "ALTER TABLE invoices ADD CONSTRAINT invoices_status_check CHECK (status IN ('draft', 'open', 'paid', 'void', 'uncollectible'))",
      "ALTER TABLE invoices DROP CONSTRAINT IF EXISTS invoices_status_check"
    )
  end
end
