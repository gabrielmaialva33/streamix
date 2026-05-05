defmodule Streamix.Repo.Migrations.CreatePayments do
  use Ecto.Migration

  def change do
    create table(:payments) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :plan_id, references(:plans, on_delete: :restrict), null: false
      add :subscription_id, references(:subscriptions, on_delete: :nilify_all)
      add :provider, :string, null: false
      add :status, :string, null: false
      add :external_id, :string
      add :amount_cents, :integer, null: false
      add :currency, :string, null: false
      add :paid_at, :utc_datetime
      add :failure_reason, :string
      add :raw_event, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:payments, [:user_id])
    create index(:payments, [:plan_id])
    create index(:payments, [:subscription_id])
    create index(:payments, [:status])
    create unique_index(:payments, [:provider, :external_id], where: "external_id IS NOT NULL")

    execute(
      "ALTER TABLE payments ADD CONSTRAINT payments_status_check CHECK (status IN ('pending', 'paid', 'failed', 'refunded', 'canceled'))",
      "ALTER TABLE payments DROP CONSTRAINT IF EXISTS payments_status_check"
    )
  end
end
