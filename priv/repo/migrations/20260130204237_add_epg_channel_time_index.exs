defmodule Streamix.Repo.Migrations.AddEpgChannelTimeIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # Index for "now playing" queries: find current program for a channel
    # Covers: WHERE provider_id = ? AND epg_channel_id = ? AND start_time <= now AND end_time > now
    create index(:epg_programs, [:provider_id, :epg_channel_id, :start_time, :end_time],
             name: :epg_programs_channel_time_idx,
             concurrently: true
           )
  end
end
