defmodule Streamix.Repo.Migrations.AddProviderGames do
  use Ecto.Migration

  def change do
    alter table(:providers) do
      add :games_enabled, :boolean, default: false, null: false
    end

    create table(:sports_matches) do
      add :provider_id, references(:providers, on_delete: :delete_all), null: false
      add :external_key, :string, null: false
      add :league, :string, null: false
      add :title, :string, null: false
      add :home_name, :string, null: false
      add :home_logo_url, :string, size: 2048
      add :away_name, :string, null: false
      add :away_logo_url, :string, size: 2048
      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime, null: false
      add :live_channel_id, references(:live_channels, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create unique_index(:sports_matches, [:provider_id, :external_key])
    create index(:sports_matches, [:live_channel_id])
    create index(:sports_matches, [:starts_at])
    create index(:sports_matches, [:ends_at])
    create constraint(:sports_matches, :valid_match_window, check: "ends_at > starts_at")
  end
end
