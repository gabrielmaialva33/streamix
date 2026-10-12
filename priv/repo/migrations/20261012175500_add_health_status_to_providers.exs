defmodule Streamix.Repo.Migrations.AddHealthStatusToProviders do
  use Ecto.Migration

  # `is_active` is the operator's switch. `health_status` is set and cleared
  # automatically when playback through a provider is systematically failing,
  # so recovery can never re-enable a provider an operator turned off.
  #
  # Expand-only: the columns are additive, the NOT NULL column carries a
  # constant default (a metadata-only change on PostgreSQL 11+), and code from
  # the previous release neither reads nor writes them.
  def change do
    alter table(:providers) do
      add :health_status, :string, null: false, default: "healthy"
      add :degraded_at, :utc_datetime
      add :degraded_reason, :string
    end

    create constraint(:providers, :providers_health_status_check,
             check: "health_status IN ('healthy', 'degraded')"
           )
  end
end
