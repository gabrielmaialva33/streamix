defmodule Streamix.Repo.Migrations.AddXtreamDeliveryProbeFields do
  use Ecto.Migration

  # `direct_client_playback` is an operator-only provider switch: VOD of such
  # a provider has its delivery decided per item at play time by probing its
  # sources, and a progressive source is handed to the client (see
  # docs/xtream-direct-playback.md). It is never cast from user params.
  #
  # `source_ids` keeps the ids of an item's upstream `sources` (the
  # `?source=N` selector), in the provider's order, so the probe knows which
  # sources exist instead of guessing.
  #
  # Expand-only: every column is additive, the NOT NULL one carries a
  # constant default (metadata-only on PostgreSQL 11+), and the previous
  # release neither reads nor writes them.
  def change do
    alter table(:providers) do
      add :direct_client_playback, :boolean, null: false, default: false
    end

    alter table(:movies) do
      add :source_ids, {:array, :integer}
    end

    alter table(:episodes) do
      add :source_ids, {:array, :integer}
    end
  end
end
