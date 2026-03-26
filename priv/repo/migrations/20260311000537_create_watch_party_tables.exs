defmodule Streamix.Repo.Migrations.CreateWatchPartyTables do
  use Ecto.Migration

  def change do
    create table(:watch_party_rooms) do
      add :invite_code, :string, null: false
      add :host_user_id, references(:users, on_delete: :delete_all), null: false
      add :content_type, :string, null: false
      add :content_id, :integer, null: false
      add :content_name, :string
      add :content_icon, :text
      add :status, :string, null: false, default: "active"
      add :max_participants, :integer, null: false, default: 10
      add :settings, :map, default: %{}
      add :ended_at, :utc_datetime

      timestamps()
    end

    create unique_index(:watch_party_rooms, [:invite_code])
    create index(:watch_party_rooms, [:host_user_id])
    create index(:watch_party_rooms, [:status])

    create table(:watch_party_participants) do
      add :room_id, references(:watch_party_rooms, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "viewer"
      add :joined_at, :utc_datetime, null: false
      add :left_at, :utc_datetime

      timestamps()
    end

    create index(:watch_party_participants, [:room_id])
    create index(:watch_party_participants, [:user_id])

    create unique_index(:watch_party_participants, [:room_id, :user_id],
             where: "left_at IS NULL",
             name: :watch_party_participants_active_unique
           )

    create table(:watch_party_messages) do
      add :room_id, references(:watch_party_rooms, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :content, :text, null: false
      add :type, :string, null: false, default: "text"

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:watch_party_messages, [:room_id, :inserted_at])
  end
end
