defmodule Streamix.Repo.Migrations.CreateCheckoutSessions do
  use Ecto.Migration

  def change do
    create table(:checkout_sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :plan_id, references(:plans, on_delete: :restrict), null: false
      add :provider, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :external_id, :string
      add :checkout_url, :string
      add :success_url, :string
      add :cancel_url, :string
      add :amount_cents, :integer, null: false
      add :currency, :string, null: false
      add :expires_at, :utc_datetime
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:checkout_sessions, [:user_id])
    create index(:checkout_sessions, [:plan_id])

    create unique_index(:checkout_sessions, [:provider, :external_id],
             where: "external_id IS NOT NULL"
           )

    execute(
      "ALTER TABLE checkout_sessions ADD CONSTRAINT checkout_sessions_status_check CHECK (status IN ('pending', 'open', 'completed', 'expired', 'canceled', 'failed'))",
      "ALTER TABLE checkout_sessions DROP CONSTRAINT IF EXISTS checkout_sessions_status_check"
    )
  end
end
