defmodule Streamix.Repo.Migrations.LiveChannels do
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

    # Índice para busca por nome (pg_trgm)
    execute(
      "CREATE INDEX live_channels_name_trgm_idx ON live_channels USING gin (name gin_trgm_ops)",
      "DROP INDEX live_channels_name_trgm_idx"
    )
  end
end
