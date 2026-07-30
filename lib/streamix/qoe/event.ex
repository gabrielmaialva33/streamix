defmodule Streamix.Qoe.Event do
  @moduledoc false

  use Ecto.Schema

  schema "qoe_events" do
    field :user_id, :integer
    field :dedupe_key, :string
    field :batch_id, :string
    field :sample_index, :integer
    field :kind, :string
    field :event, :string
    field :outcome, :string
    field :engine, :string
    field :content_type, :string
    field :stream_type, :string
    field :surface, :string
    field :display_mode, :string
    field :device_class, :string, default: "unknown"
    field :ttff_ms, :integer
    field :buffer_count, :integer, default: 0
    field :buffer_duration_ms, :integer, default: 0
    field :session_duration_ms, :integer
    field :error_count, :integer, default: 0
    field :fallback_count, :integer, default: 0
    field :muted_mismatch, :boolean, default: false
    field :lcp_ms, :integer
    field :inp_ms, :integer
    field :cls_milli, :integer

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end
end
