defmodule Streamix.Repo.Migrations.CreateEpgPrograms do
  use Ecto.Migration

  def change do
    create table(:epg_programs) do
      add :epg_channel_id, :string, null: false
      add :title, :text, null: false
      add :description, :text
      add :start_time, :utc_datetime, null: false
      add :end_time, :utc_datetime, null: false
      add :category, :string
      add :icon, :text
      add :lang, :string, size: 10
      add :provider_id, references(:providers, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    # For "what's on now" queries
    create index(:epg_programs, [:provider_id, :start_time, :end_time])

    # Unique constraint to prevent duplicates during sync (also serves as primary lookup index)
    create unique_index(:epg_programs, [:provider_id, :epg_channel_id, :start_time])
  end
end
