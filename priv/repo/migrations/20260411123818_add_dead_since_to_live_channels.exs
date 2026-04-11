defmodule Streamix.Repo.Migrations.AddDeadSinceToLiveChannels do
  use Ecto.Migration

  def change do
    alter table(:live_channels) do
      # When set, the upstream returned 404/unplayable at this timestamp.
      # Null = healthy. Channels stay hidden until the value ages out
      # (recheck window) or is cleared by a successful resolve / sync.
      add :dead_since, :utc_datetime
    end

    # Partial index: only the few dead channels live here, keeping lookups cheap.
    create index(:live_channels, [:dead_since], where: "dead_since IS NOT NULL")
  end
end
