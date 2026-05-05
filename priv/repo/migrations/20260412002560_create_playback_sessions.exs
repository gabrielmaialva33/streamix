defmodule Streamix.Repo.Migrations.CreatePlaybackSessions do
  use Ecto.Migration

  def change do
    create table(:playback_sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :session_id, :string, null: false
      add :content_type, :string, null: false
      add :content_id, :integer, null: false
      add :status, :string, null: false, default: "active"
      add :started_at, :utc_datetime, null: false
      add :last_seen_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:playback_sessions, [:user_id, :status])
    create index(:playback_sessions, [:last_seen_at])
    create unique_index(:playback_sessions, [:session_id])

    execute(
      "ALTER TABLE playback_sessions ADD CONSTRAINT playback_sessions_status_check CHECK (status IN ('active', 'ended'))",
      "ALTER TABLE playback_sessions DROP CONSTRAINT IF EXISTS playback_sessions_status_check"
    )
  end
end
