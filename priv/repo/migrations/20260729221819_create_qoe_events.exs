defmodule Streamix.Repo.Migrations.CreateQoeEvents do
  use Ecto.Migration

  def change do
    create table(:qoe_events) do
      add :user_id, references(:users, on_delete: :nilify_all)
      add :dedupe_key, :string, null: false
      add :batch_id, :string, null: false
      add :sample_index, :integer, null: false
      add :kind, :string, null: false
      add :event, :string
      add :outcome, :string
      add :engine, :string
      add :content_type, :string
      add :stream_type, :string
      add :surface, :string
      add :display_mode, :string
      add :ttff_ms, :integer
      add :buffer_count, :integer, null: false, default: 0
      add :buffer_duration_ms, :integer, null: false, default: 0
      add :session_duration_ms, :integer
      add :error_count, :integer, null: false, default: 0
      add :fallback_count, :integer, null: false, default: 0
      add :muted_mismatch, :boolean, null: false, default: false
      add :lcp_ms, :integer
      add :inp_ms, :integer
      add :cls_milli, :integer

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:qoe_events, [:dedupe_key])
    create index(:qoe_events, [:inserted_at])
    create index(:qoe_events, [:kind, :inserted_at])
    create index(:qoe_events, [:user_id, :inserted_at])

    create constraint(:qoe_events, :qoe_events_nonnegative_counts,
             check:
               "buffer_count >= 0 AND buffer_duration_ms >= 0 AND " <>
                 "error_count >= 0 AND fallback_count >= 0"
           )

    create constraint(:qoe_events, :qoe_events_valid_kind,
             check: "kind IN ('playback', 'pwa', 'web_vital')"
           )
  end
end
