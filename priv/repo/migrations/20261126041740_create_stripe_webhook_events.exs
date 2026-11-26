defmodule Streamix.Repo.Migrations.CreateStripeWebhookEvents do
  use Ecto.Migration

  def change do
    create table(:stripe_webhook_events, primary_key: false) do
      add :external_id, :string, primary_key: true
      add :event_type, :string, null: false
      add :processed_at, :utc_datetime, null: false
    end
  end
end
