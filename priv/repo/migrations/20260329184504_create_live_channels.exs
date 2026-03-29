defmodule Streamix.Repo.Migrations.CreateLiveChannels do
  use Ecto.Migration

  def change do
    create table(:live_channels) do
      add :stream_id, :integer, null: false
      add :name, :text, null: false
      add :stream_icon, :text
      add :epg_channel_id, :string
      add :tv_archive, :boolean, default: false
      add :tv_archive_duration, :integer
      add :direct_source, :text
      add :provider_id, references(:providers, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:live_channels, [:provider_id])
    create unique_index(:live_channels, [:provider_id, :stream_id])
    create index(:live_channels, [:provider_id, :name])

    execute(
      "CREATE INDEX live_channels_name_trgm_idx ON live_channels USING gin (name gin_trgm_ops)",
      "DROP INDEX live_channels_name_trgm_idx"
    )

    # Junction table
    create table(:live_channel_categories, primary_key: false) do
      add :live_channel_id, references(:live_channels, on_delete: :delete_all), null: false
      add :category_id, references(:categories, on_delete: :delete_all), null: false
    end

    create unique_index(:live_channel_categories, [:live_channel_id, :category_id])
    create index(:live_channel_categories, [:category_id])
  end
end
