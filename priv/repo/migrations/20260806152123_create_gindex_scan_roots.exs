defmodule Streamix.Repo.Migrations.CreateGindexScanRoots do
  use Ecto.Migration

  def change do
    create table(:gindex_scan_roots) do
      add :provider_id, references(:providers, on_delete: :delete_all), null: false
      add :base_url, :string, null: false
      add :root_path, :string, null: false
      add :kind, :string, null: false
      add :position, :integer, null: false, default: 0
      add :cycle_id, :uuid, null: false
      add :status, :string, null: false, default: "pending"
      add :cursor, :map, null: false, default: %{}
      add :stats, :map, null: false, default: %{}
      add :last_error, :map
      add :paused_reason, :string
      add :quota_count, :integer
      add :next_resume_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :last_progress_at, :utc_datetime_usec
      add :attempt_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gindex_scan_roots, [:provider_id, :root_path, :kind])
    create index(:gindex_scan_roots, [:provider_id, :cycle_id, :status])
    create index(:gindex_scan_roots, [:provider_id, :last_progress_at])

    create constraint(:gindex_scan_roots, :gindex_scan_roots_valid_kind,
             check: "kind IN ('movies', 'series', 'animes')"
           )

    create constraint(:gindex_scan_roots, :gindex_scan_roots_valid_status,
             check: "status IN ('pending', 'running', 'paused', 'completed', 'failed')"
           )

    create constraint(:gindex_scan_roots, :gindex_scan_roots_non_negative_counters,
             check:
               "position >= 0 AND attempt_count >= 0 AND (quota_count IS NULL OR quota_count >= 0)"
           )
  end
end
