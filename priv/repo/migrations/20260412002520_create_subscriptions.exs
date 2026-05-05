defmodule Streamix.Repo.Migrations.CreateSubscriptions do
  use Ecto.Migration

  def change do
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

    create index(:subscriptions, [:user_id, :expires_at],
             where: "status = 'active'",
             name: :subscriptions_active_idx
           )

    execute(
      "ALTER TABLE subscriptions ADD CONSTRAINT subscriptions_status_check CHECK (status IN ('active', 'expired', 'canceled', 'pending'))",
      "ALTER TABLE subscriptions DROP CONSTRAINT IF EXISTS subscriptions_status_check"
    )
  end
end
