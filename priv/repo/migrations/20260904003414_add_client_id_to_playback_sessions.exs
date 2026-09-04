defmodule Streamix.Repo.Migrations.AddClientIdToPlaybackSessions do
  use Ecto.Migration

  def change do
    alter table(:playback_sessions) do
      # Stable per-tab identifier sent by the browser on socket connect. A
      # reconnect or same-tab navigation supersedes the previous session of
      # the same client instead of counting as a second screen.
      add :client_id, :string
    end

    create index(:playback_sessions, [:user_id, :client_id],
             where: "status = 'active'",
             name: :playback_sessions_active_client_index
           )
  end
end
