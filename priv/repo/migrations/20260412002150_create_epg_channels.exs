defmodule Streamix.Repo.Migrations.CreateEpgChannels do
  use Ecto.Migration

  def change do
    create table(:epg_channels) do
      add :external_id, :string, null: false
      add :name, :string
      add :icon, :text
      add :provider_id, references(:providers, on_delete: :delete_all), null: false
      add :live_channel_id, references(:live_channels, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:epg_channels, [:provider_id, :external_id])
    create index(:epg_channels, [:live_channel_id])
  end
end
