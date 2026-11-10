defmodule Streamix.Repo.Migrations.AddPlaybackExplanationsToQoeEvents do
  use Ecto.Migration

  def change do
    alter table(:qoe_events) do
      add :end_reason, :string
      add :engine_reason, :string
      add :client_revision, :string
    end
  end
end
