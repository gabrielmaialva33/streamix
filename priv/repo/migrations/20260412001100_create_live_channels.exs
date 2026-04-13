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
      add :dead_since, :utc_datetime
      add :provider_id, references(:providers, on_delete: :delete_all), null: false
      add :catalog_item_id, :bigint, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:live_channels, [:provider_id])
    create unique_index(:live_channels, [:provider_id, :stream_id])
    create index(:live_channels, [:provider_id, :name])
    create index(:live_channels, [:dead_since], where: "dead_since IS NOT NULL")

    execute(
      "CREATE INDEX live_channels_name_trgm_idx ON live_channels USING gin (name gin_trgm_ops)",
      "DROP INDEX live_channels_name_trgm_idx"
    )

    create unique_index(:live_channels, [:catalog_item_id])

    execute(
      """
      ALTER TABLE live_channels
        ADD CONSTRAINT live_channels_catalog_item_provider_fk
        FOREIGN KEY (catalog_item_id, provider_id)
        REFERENCES catalog_items (id, provider_id)
        ON DELETE RESTRICT
      """,
      "ALTER TABLE live_channels DROP CONSTRAINT IF EXISTS live_channels_catalog_item_provider_fk"
    )
  end
end
