defmodule Streamix.Gindex.ScanRoot do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(pending running paused completed failed)
  @kinds ~w(movies series animes)

  @timestamps_opts [type: :utc_datetime_usec]

  schema "gindex_scan_roots" do
    field :base_url, :string
    field :root_path, :string
    field :kind, :string
    field :position, :integer, default: 0
    field :cycle_id, Ecto.UUID
    field :status, :string, default: "pending"
    field :cursor, :map, default: %{}
    field :stats, :map, default: %{}
    field :last_error, :map
    field :paused_reason, :string
    field :quota_count, :integer
    field :next_resume_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :last_progress_at, :utc_datetime_usec
    field :attempt_count, :integer, default: 0

    field :provider_id, :id

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(scan_root, attrs) do
    scan_root
    |> cast(attrs, [
      :provider_id,
      :base_url,
      :root_path,
      :kind,
      :position,
      :cycle_id,
      :status,
      :cursor,
      :stats,
      :last_error,
      :paused_reason,
      :quota_count,
      :next_resume_at,
      :started_at,
      :completed_at,
      :last_progress_at,
      :attempt_count
    ])
    |> validate_required([
      :provider_id,
      :base_url,
      :root_path,
      :kind,
      :position,
      :cycle_id,
      :status
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_number(:quota_count, greater_than_or_equal_to: 0)
    |> unique_constraint([:provider_id, :root_path, :kind])
    |> foreign_key_constraint(:provider_id)
  end
end
